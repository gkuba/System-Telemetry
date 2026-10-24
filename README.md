# System Telemetry

A small Linux telemetry logger for diagnosing GPU crashes, PCIe faults, and storage issues.

## What it records

- GPU power, load, temperature, clocks, fan, VRAM, and PCIe link status
- Board 12 V and VRM MOS temperature, when available
- GPU and NVMe PCIe link speed, width, and AER error counters
- Kernel warnings related to GPU, PCIe, NVMe, storage, and early boot
- Board, BIOS, and kernel version at logger startup

NVMe SMART data is not collected by the service because it lacks device permissions. Gather it manually when needed with `sudo smartctl -x /dev/nvme0` and the relevant device path.

## Run

Run the logger with its dashboard in a terminal:

```bash
./system-telemetry.sh
```

The default mode checks whether a logger is already running. If one is, another launch opens a read-only dashboard using the active logs; it does not start a second logger or overwrite its data.

Run without drawing a dashboard (used by the system service):

```bash
./system-telemetry.sh --headless
```

`--no-display` is an alias for `--headless`.

The service installer creates a local systemd unit for the current user and checkout path, then enables and starts it. Run it from any location:

```bash
./install-service.sh
```

The installer asks for sudo access to install the unit. It reads `system-telemetry.service.in`; the generated, machine-specific unit is installed under `/etc/systemd/system/` and is not stored in the repository.

## Logs

Logs are written to `logs/` beside the script. They rotate automatically; `/logs/` is ignored by Git so generated telemetry is not committed.
