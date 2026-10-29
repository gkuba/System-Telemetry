# System Telemetry

A Linux logger for chasing an NVIDIA GPU that drops off the bus (black screen, fans at 100%). It samples the GPU every 2 seconds, watches the kernel log for driver failures, and saves a crash bundle the moment the GPU is lost, so every failure leaves evidence behind.

## What it records

- **GPU samples** (`logs/telemetry.csv`): P-state, power and limit, load, temperature, clocks, PCIe link, VRAM use, fan, and the active clock-limit reasons (idle, power cap, thermal, power brake).
- **VRAM health** (`logs/health.csv`): remapped-row counts and the bank-availability histogram at every start and hourly, plus driver, VBIOS and ECC mode. A rise in remapped rows is recorded as an alert; it is the clearest hardware evidence the card can give.
- **Events** (`logs/events.log`): logger starts, every NVIDIA Xid, the first occurrence of each other NVRM/PCIe/AER kernel message (repeats are counted, not copied), GPU lost and recovered, and new kernel panic dumps in `/var/lib/systemd/pstore`.
- **Crash bundles** (`logs/crashes/<time>/`): written when the driver reports a GPU failure (Xid 79, 119, 48 and similar, scrub timeouts, "fallen off the bus") or `nvidia-smi` stops answering. Bundles are never rotated away.

Each bundle holds:

| File | Contents |
| --- | --- |
| `summary.txt` | Trigger, first error line, boot ID, kernel, board, BIOS, microcode, last VRAM health snapshot |
| `telemetry.csv` | The last ~10 minutes of samples before the failure |
| `kernel.log` | Kernel log from 15 minutes before the failure, recaptured 90 seconds after it |
| `pci.txt`, `pci-after.txt` | PCIe link and AER counters for the GPU and its root port, at the failure and 90 seconds later |
| `nvidia-smi-q.txt` | Full `nvidia-smi -q`, if the GPU still answered |
| `kernel-previous-boot.log` | Added at the next start when the failure ended the boot |

If the logger misses a failure live (it was not running, or the machine froze), the next start finds it in the previous boot's journal and builds a bundle from the journal and the saved samples.

## Requirements

- Bash 5 and an NVIDIA GPU with the NVIDIA driver (`nvidia-smi`)
- coreutils (`timeout`, `stat`), util-linux (`flock`), procps (`pkill`), and `journalctl`
- Read access to the kernel journal: the service gets it through the `systemd-journal` group

## Files

| File | Purpose |
| --- | --- |
| `system-telemetry.sh` | The logger and dashboard |
| `crash-reboot.py` | Root key listener for the Super + Alt + Delete emergency reboot |
| `install-service.sh` | Generates both units from their templates and installs, enables and restarts them |
| `system-telemetry.service.in`, `crash-reboot.service.in` | Unit templates; `@USER@`, `@HOME@` and `@INSTALL_DIR@` are filled in by the installer |

## Run

Run the logger with its dashboard:

```bash
./system-telemetry.sh
```

If a logger is already running (for example the service), this opens a read-only dashboard of its data instead of starting a second logger.

Run without the dashboard (used by the service):

```bash
./system-telemetry.sh --headless
```

Install the logger and the emergency-reboot listener as system services for the current user and checkout path:

```bash
./install-service.sh
```

The installer asks for sudo, writes the unit to `/etc/systemd/system/`, and enables and restarts it. The unit runs the script from this checkout, so run the installer again whenever the folder moves or is renamed.

Check on the service with `systemctl status system-telemetry` and `journalctl -u system-telemetry`.

## Keep the journal

The previous-boot check can only read what journald kept. With a small journal cap, older boots are deleted within days. Raise the cap in `/etc/systemd/journald.conf`:

```ini
[Journal]
SystemMaxUse=1G
```

Then restart journald with `sudo systemctl restart systemd-journald`.

## Emergency reboot: hold Super + Alt + Delete

When the GPU drops off the bus the screen goes black, but Linux keeps running. Holding the power button skips the clean shutdown and can damage the filesystem. Instead, hold **Super + Alt + Delete for 3 seconds**:

1. Caps Lock blinks three times to confirm.
2. The kernel log is saved into this boot's crash bundle as `kernel-at-reboot.log`.
3. Disks are synced and the machine reboots cleanly.
4. If the clean reboot hangs for 45 seconds (unloading the NVIDIA driver can block on a dead GPU), it is forced through `/proc/sysrq-trigger`: sync, remount read-only, reboot.

`crash-reboot.py` runs as root in `crash-reboot.service` and reads keyboards straight from the kernel, so it works even when the desktop has died with the GPU. A KDE shortcut would not: KWin runs on the GPU. It only watches for the combo and never grabs, remaps or records keys. It needs `python-evdev`.

Test it without rebooting; this saves the log and blinks Caps Lock, then keeps listening:

```bash
sudo systemctl stop crash-reboot
sudo python3 -I crash-reboot.py --dry-run
sudo systemctl start crash-reboot
```

## After a crash

1. Reboot with Super + Alt + Delete and let the service start; it adds the previous boot's kernel log to the bundle.
2. Run `sudo nvidia-bug-report.sh` and keep the archive with the bundle.
3. Compare the newest row of `logs/health.csv` with older rows to see whether remapped rows went up.

Logs are written to `logs/` beside the script, and `/logs/` is ignored by Git. Set `TELEMETRY_LOG_DIR` to log somewhere else.
