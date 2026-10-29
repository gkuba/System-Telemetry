#!/usr/bin/env python3
"""Emergency reboot for GPU crashes: hold Super+Alt+Delete for 3 seconds.

Runs as root and reads keyboards straight from the kernel, so it still works
after the GPU, and the desktop with it, has died. It only watches for the
combo: it never grabs, remaps or records the keyboard.

On the combo it blinks Caps Lock to confirm, saves the kernel log into the
current crash bundle, syncs, and reboots cleanly. If the clean reboot hangs
(unloading the NVIDIA driver can block on a dead GPU), it forces one through
/proc/sysrq-trigger: sync, remount read-only, reboot.
"""

import argparse
import os
import selectors
import signal
import subprocess
import time
from datetime import datetime
from pathlib import Path

import evdev
from evdev import ecodes as e

HOLD_SECONDS = 3.0
RESCAN_SECONDS = 5.0           # picks up keyboards that reconnect (wireless, KVM)
REBOOT_FALLBACK_SECONDS = 45
KERNEL_LOOKBACK = "-20min"

SUPER = {e.KEY_LEFTMETA, e.KEY_RIGHTMETA}
ALT = {e.KEY_LEFTALT, e.KEY_RIGHTALT}
DELETE = {e.KEY_DELETE}

LOG_DIR = Path(os.environ.get("TELEMETRY_LOG_DIR", Path(__file__).resolve().parent / "logs"))


def log(message):
    print(message, flush=True)


def combo_held(pressed):
    return bool(pressed & SUPER) and bool(pressed & ALT) and bool(pressed & DELETE)


class Watcher:
    def __init__(self):
        self.selector = selectors.DefaultSelector()
        self.devices = {}   # path -> InputDevice
        self.pressed = {}   # path -> keys held on that device
        self.held_since = None

    def rescan(self):
        for path in evdev.list_devices():
            if path in self.devices:
                continue
            try:
                device = evdev.InputDevice(path)
                keys = device.capabilities().get(e.EV_KEY, [])
            except OSError:
                continue
            if e.KEY_DELETE not in keys:
                device.close()
                continue
            self.devices[path] = device
            self.pressed[path] = set()
            self.selector.register(device, selectors.EVENT_READ, path)
            log(f"watching {device.name} ({path})")

    def drop(self, path):
        device = self.devices.pop(path)
        self.pressed.pop(path, None)
        self.selector.unregister(device)
        device.close()
        log(f"lost {path}")

    def held_keys(self):
        # Modifiers and Delete can arrive on different interfaces of one keyboard.
        return set().union(*self.pressed.values())

    def wait_for_combo(self, require_release=False):
        """Return once the combo has been held for HOLD_SECONDS.

        With require_release, the combo must be let go first, so one long
        press cannot trigger twice.
        """
        next_scan = 0.0
        self.held_since = None
        armed = not require_release
        while True:
            now = time.monotonic()
            if now >= next_scan:
                self.rescan()
                next_scan = now + RESCAN_SECONDS
            deadline = next_scan
            if self.held_since is not None:
                deadline = min(deadline, self.held_since + HOLD_SECONDS)
            for key, _ in self.selector.select(max(deadline - now, 0)):
                path = key.data
                try:
                    for event in self.devices[path].read():
                        if event.type != e.EV_KEY:
                            continue
                        if event.value:          # 1 = press, 2 = autorepeat
                            self.pressed[path].add(event.code)
                        else:
                            self.pressed[path].discard(event.code)
                except (OSError, KeyError):
                    if path in self.devices:
                        self.drop(path)
            if not combo_held(self.held_keys()):
                self.held_since = None
                armed = True
            elif not armed:
                continue
            elif self.held_since is None:
                self.held_since = time.monotonic()
            elif time.monotonic() - self.held_since >= HOLD_SECONDS:
                return

    def blink(self, times=3):
        """Flash Caps Lock: the only feedback possible with a black screen."""
        leds = []
        for device in self.devices.values():
            try:
                if e.LED_CAPSL in device.capabilities().get(e.EV_LED, []):
                    leds.append((device, e.LED_CAPSL in device.leds()))
            except OSError:
                pass
        for _ in range(times):
            for state in (1, 0):
                for device, _ in leds:
                    try:
                        device.set_led(e.LED_CAPSL, state)
                    except OSError:
                        pass
                time.sleep(0.15)
        for device, was_on in leds:
            try:
                device.set_led(e.LED_CAPSL, int(was_on))
            except OSError:
                pass


def log_event(text):
    events = LOG_DIR / "events.log"
    if not events.exists():
        return
    stamp = datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")
    try:
        with events.open("a") as handle:
            handle.write(f"[{stamp}] [reboot] {text}\n")
    except OSError:
        pass


def current_bundle():
    """The newest crash bundle from this boot, if the logger saved one."""
    boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip().replace("-", "")
    for bundle in sorted((LOG_DIR / "crashes").glob("*/"), reverse=True):
        try:
            if (bundle / "boot_id").read_text().strip() == boot_id:
                return bundle
        except OSError:
            continue
    return None


def save_kernel_log():
    bundle = current_bundle()
    if bundle is None:
        log("no crash bundle for this boot; the journal still has the kernel log")
        return
    target = bundle / "kernel-at-reboot.log"
    try:
        with target.open("w") as handle:
            subprocess.run(["journalctl", "-k", "-b", "0", "--since", KERNEL_LOOKBACK,
                            "-o", "short-iso-precise", "--no-pager"],
                           stdout=handle, stderr=subprocess.STDOUT, timeout=15)
        owner = bundle.stat()
        os.chown(target, owner.st_uid, owner.st_gid)   # keep the bundle readable by its owner
        log(f"kernel log saved to {target}")
    except (OSError, subprocess.TimeoutExpired) as error:
        log(f"could not save the kernel log: {error}")


def sysrq(*commands):
    for command in commands:
        try:
            Path("/proc/sysrq-trigger").write_text(command)
        except OSError as error:
            log(f"sysrq {command} failed: {error}")
        time.sleep(2)


def reboot(dry_run):
    log("Super+Alt+Delete held: rebooting")
    log_event("Super+Alt+Delete held: saving logs and rebooting" + (" (dry run)" if dry_run else ""))
    save_kernel_log()
    if dry_run:
        log("dry run: would sync, run systemctl reboot, and force a reboot "
            f"after {REBOOT_FALLBACK_SECONDS}s")
        return
    # Outlive the shutdown so the fallback below can still fire if it hangs.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.sync()
    try:
        subprocess.run(["systemctl", "reboot"], timeout=10)
    except (OSError, subprocess.TimeoutExpired) as error:
        log(f"systemctl reboot failed: {error}")
    time.sleep(REBOOT_FALLBACK_SECONDS)
    log("clean reboot did not finish; forcing it")
    sysrq("s", "u", "b")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true",
                        help="do everything except sync and reboot, then keep listening")
    args = parser.parse_args()
    watcher = Watcher()
    require_release = False
    while True:
        watcher.wait_for_combo(require_release)
        watcher.blink()
        reboot(args.dry_run)
        if not args.dry_run:
            return
        require_release = True


if __name__ == "__main__":
    main()
