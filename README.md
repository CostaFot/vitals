# vitals

Watches the handful of things that can take this desktop down and puts a notification on screen when one of them starts going wrong. Arch, systemd user timer, once a minute.

There is no web UI, no metrics database and no bar widget.

## What it watches

| Check | Fires when |
|---|---|
| CPU idle floor | the median `Tccd2` across idle samples from the last 24h goes above 65C |
| CPU hard limit | `Tctl` hits 85C, whatever the load is doing |
| NVMe temperature | a drive passes its own warning or critical limit |
| SMART | health fails, a critical warning is set, spare blocks hit the floor, media errors appear, or wear passes 90% |
| Unsafe shutdowns | the drive's counter goes up |
| Disk space | `/` above 85%, `/boot` above 80% |
| GPU | 80C, 88C, or a fan reading 0% while the card is above 50C |
| Kernel log | machine checks, or NVRM allocation failures |

The idle floor is the one worth explaining. The AIO sits on a board header and the IT8688E chip on this motherboard has no driver bound, so `sensors` reports no pump RPM at all — if the pump weakens, nothing says so. What does change is the temperature the CPU settles at when nothing is happening. So only the samples taken while the load average was low are kept, and the median of those is what gets watched.

Drive limits are not in the config. Each NVMe reports its own `temp1_max` and `temp1_crit`, so the 990 EVO Plus is judged at 81C and the 980 PRO at 82C without either number being written down anywhere.

NVRM allocation failures are in there because they are what the GPU says just before Brave's media processes start dying.

## Install

```sh
git clone <this repo> ~/Work/vitals
cd ~/Work/vitals
./install.sh
```

Symlinks the script into `~/.local/bin` and enables a user timer. No root.

SMART attributes need root to read, so they are a separate hourly system timer:

```sh
./install.sh --with-smart
```

Until that one is installed, `vitals status` says SMART is unavailable and everything else works normally.

`./uninstall.sh` takes both halves back off and leaves the collected samples alone.

## Use

```sh
vitals status    # what everything reads right now
vitals log       # alerts that fired, and when they cleared
vitals check     # run every probe now
vitals probe     # raw readings as JSON
```

```
load   0.68
cpu    Tccd1 65.2C  Tccd2 47.0C  Tctl 61.4C
       idle floor: not enough idle samples yet (16/30)
gpu    NVIDIA GeForce RTX 3080  44C  fan 47%  29W  1093/12288 MiB
drive  Samsung SSD 980 PRO 1TB: Composite 49.9C  Sensor 1 49.9C  Sensor 2 57.9C  (warn 82C)
drive  Samsung SSD 990 EVO Plus 2TB: Composite 46.9C  Sensor 1 64.8C  Sensor 2 46.9C  (warn 81C)
disk   /  20% used, 1482.0G free
disk   /boot  20% used, 1.6G free
smart  Samsung SSD 980 PRO 1TB: PASSED, 7% used, spare 100%, 0 media errors, 88 unsafe shutdowns
smart  Samsung SSD 990 EVO Plus 2TB: PASSED, 0% used, spare 100%, 0 media errors, 8 unsafe shutdowns
       (read 0.0h ago)

nothing firing
```

## Configuration

Optional. Anything in `~/.config/vitals/config.toml` overrides the defaults:

```toml
idle_floor_warn = 62.0      # median idle Tccd2 that counts as a problem
idle_load_max = 1.0         # load1 below this counts as idle
cpu_tctl_crit = 85.0
gpu_temp_warn = 80.0
disk_warn_pct = 85.0
cooldown_warn_hours = 6     # how long before the same warning nags again
```

A broken config file is ignored with a complaint rather than taking the monitor down with it.

## Notes and limitations

Alerts go to the desktop and nowhere else, because this machine is attended. Everything leaves through one `deliver()` function, so ntfy or email is a small change if that stops being true.

The idle floor stays quiet until it has 30 idle samples, so a fresh install says nothing useful for the first half hour.

The kernel log is read through a `journalctl` cursor seeded at install, so hardware errors from before then are not re-litigated.

The shape of this machine is assumed throughout: an AMD CPU on `k10temp`, an NVIDIA card reachable through `nvidia-smi`, NVMe storage. Nothing auto-detects an Intel box or an AMD GPU.

Fan and pump RPM stay unreadable. `it87-dkms` would expose the headers for the price of `acpi_enforce_resources=lax` in the boot args, which is a worse trade than it sounds when temperature already answers the question.
