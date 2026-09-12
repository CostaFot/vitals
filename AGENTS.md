# AGENTS.md

## Board

Linear team `COS`, project **vitals**, area label `infra`.
Parent issue: COS-183. Related hardware issues: COS-182 (the AIO), COS-181 (UPS).
Read the `board` skill before touching any of it.

## Shape

One Python file, `vitals`, stdlib only, no dependencies. Two systemd timers and
one daemon that is not ours do the watching; a scheduled agent does the reading
(see The morning read below):

- `vitals.timer` (user, every minute) runs `vitals check`. Does all the probing,
  thresholding and sample recording. Needs no privileges. Notifies for one
  thing only, a stopped GPU fan.
- `vitals-root.timer` (system, hourly) runs `vitals root-probe`. Exists only
  because NVMe SMART attributes need root. It does no thresholding — it dumps
  facts to `/var/lib/vitals/root.json` (0644) and the user half decides what they
  mean. Keeping all judgement in one place is deliberate.
- `smartd` (system package) owns the drive emergencies. `-H` reads the NVMe
  critical-warning byte every 30 minutes and logs `LOG_CRIT` if any bit is set.
  `-M exec` runs `smartd-notify`, the other thing here that puts anything on screen.

`install.sh` symlinks rather than copies, so editing the repo changes what runs.
It rewrites the `DEVICESCAN` line in `/etc/smartd.conf` and keeps the original at
`/etc/smartd.conf.before-vitals`, which `uninstall.sh` puts back.

## State

Everything lives in `~/.local/state/vitals/`:

| File | Holds |
|---|---|
| `samples.csv` | one row per minute: ts, load1, Tctl, Tccd1, Tccd2, gpu temp, gpu fan. Trimmed to 30 days |
| `readings.csv` | long format (ts, metric, subject, value) for drive temperatures and disk usage, which have no fixed column count. Trimmed to 30 days |
| `smart.jsonl` | one line per hourly root probe, because `root.json` is overwritten and wear only means something as a trend |
| `alerts.json` | currently firing alerts, plus `_smart_counters` for detecting a rising unsafe-shutdown count |
| `alerts.jsonl` | append-only log of every fire and clear |
| `journal.cursor` | journalctl cursor, so each run only sees new kernel lines |
| `report.cursor` | where the last `vitals report --since-last` stopped, so the morning read never sees a window twice nor leaves a hole |

Keys in `alerts.json` that start with `_` are internal bookkeeping, not alerts;
the dispatch loop skips them when deciding what has recovered.

Two flags on `Alert` decide what happens to it, and both are carried through
`alerts.json` so the clear path can still see them:

- `event` - it happened rather than being true now (machine checks, NVRM
  failures, unsafe shutdowns, media errors). Fires once, no recovery notice.
- `emergency` - it is allowed to reach the desktop. **One check sets it**: a GPU
  fan reading 0% while the card is above 50C, confirmed across two samples a
  minute apart. It is the only failure here that gets worse unattended and that
  nothing else watches — chips throttle, disks wait, drives are smartd's. The
  four alerts that used to set it were SMART health, NVMe critical warning,
  spare exhausted and drive-at-critical-temperature, all bits in the same NVMe
  critical-warning byte that `smartd -H` reads directly (COS-188, COS-189).

  The two-sample confirm is the whole reason it can be trusted. A 3080 stops its
  fan below roughly 45C on purpose — the samples caught this card doing it at
  42-45C and spinning back up at 45C — so 0% on its own is normal, and the 50C
  gate sits above the card's own restart point. `fan_stopped()` is deliberately
  separate from `sustained()`, which tests for values *above* a threshold.

## The morning read

vitals judges almost nothing and notifies for one thing. The rest of the
judgement is a BB
automation, `auto__tpv6vzfspe` on the `vitals` project: 12:00 Europe/Athens,
Opus 5, one command, and silence unless something is worth saying. Its prompt
carries the reading rules - that a high max means nothing on chips designed to
boost into their limit but a high median does, that the idle floor is the pump
proxy, that `Sensor 1` has no limit to be judged against, and that a stopped
smartd reads exactly like a clean night. Change the rules there, not here:

```sh
bb automation show auto__tpv6vzfspe --project proj_dtsyy954sc
bb automation runs auto__tpv6vzfspe --project proj_dtsyy954sc
```

`--since-last` is what makes a missed run harmless. The window runs from the
previous marked report to now rather than a fixed 24 hours, so a day the machine
slept through gets picked up by the next run instead of falling in a hole. The
mark moves when the report prints, so running it by hand takes that window away
from the automation - use `--hours` to look around.

## Things that are easy to get wrong

**lm-sensors chip names.** `nvme-pci-0100` encodes the PCI address `0000:01:00.0`
as bus byte then `(device << 3) | function`. `nvme_chip_map()` derives it from
`/sys/class/nvme/*/device` so drive models resolve. Getting this wrong silently
falls back to printing chip names instead of models.

**Bogus sensor limits.** NVMe `Sensor 1`/`Sensor 2` report `temp*_max` of
65261.85 (the "no limit" sentinel). Anything above 1000 is discarded.

**The 990 EVO Plus runs hot on `Sensor 1`, not `Composite`.** Composite sits
around 47C while Sensor 1 is at 65C. `check_drive_temps` walks every sensor,
but only `Composite` reports usable limits on either drive, so Sensor 1 has
nothing to be judged against and never alerts. It is in `readings.csv` and in
`vitals report`, which is where it actually gets looked at.

**smartd-notify writes to the journal with no unit attached.** smartd forks the
`-M exec` target outside its own cgroup, so those lines have no `_SYSTEMD_UNIT`
and `journalctl -u smartd.service` silently misses them. `smartd_messages()`
therefore ORs two matches with `+`: `_SYSTEMD_UNIT=smartd.service` for smartd's
own `LOG_CRIT`, and `SYSLOG_IDENTIFIER=vitals-smartd` for the script's. Dropping
either one makes the report claim a quiet night that was not observed.

**Journal cursor seeding.** `journalctl` only writes `--cursor-file` for entries
it actually printed, so `--since=now` leaves the cursor unset and the next run
re-reads the whole boot. First run uses `-n 1` to seed at the newest line.

**The benign MCE banner.** `MCE: In-kernel MCE decoding enabled.` appears at
every boot and matches the `machine check` pattern. It is in `JOURNAL_IGNORE`.

**Idle-floor sampling is load-filtered on purpose.** A plain rolling average of
Tccd2 would rise with workload and alert on a busy afternoon. Only samples with
`load1 <= idle_load_max` count, and the statistic is a median so a single spike
cannot move it.

## Testing without waiting for a real fault

Drop thresholds into `~/.config/vitals/config.toml` to force an alert, then
remove the file to watch the recovery notification fire:

```sh
printf 'gpu_temp_warn = 10.0\n' > ~/.config/vitals/config.toml
vitals check
rm ~/.config/vitals/config.toml && vitals check
vitals log
```

`vitals check --quiet` evaluates and records without notifying.

The GPU fan alert is the one thing config cannot force, because it needs a real
0% reading from `nvidia-smi` as well as a threshold. Point `SAMPLES` at a fake
file and call the check directly:

```sh
python3 - <<'EOF'
import importlib.machinery, importlib.util, pathlib, sys, tempfile, time
loader = importlib.machinery.SourceFileLoader("v", "vitals")
v = importlib.util.module_from_spec(importlib.util.spec_from_loader("v", loader))
sys.modules["v"] = v; loader.exec_module(v)
now, f = time.time(), pathlib.Path(tempfile.mkstemp(suffix=".csv")[1])
f.write_text("ts,load1,tctl,tccd1,tccd2,gpu_temp,gpu_fan\n" + "".join(
    f"{now-age},0.5,60,60,50,72,0\n" for age in (0, 60, 120)))
v.SAMPLES = f
print(v.check_gpu({"gpu": {"name": "RTX 3080", "temp": 72.0, "fan": 0.0}}))
EOF
```

Change one of those `0` fan values to `47` and it must go silent — that is the
driver-hiccup case the confirm exists for.

smartd has its own end-to-end test, which runs the real `-M exec` path and puts a
real toast on screen, one per drive:

```sh
sudo sed -i 's|-M daily|-M daily -M test|' /etc/smartd.conf
sudo systemctl restart smartd.service      # two notifications appear
sudo sed -i 's| -M test||' /etc/smartd.conf
sudo systemctl restart smartd.service
```

Stopping `smartd.service` and running `vitals check` exercises the `smartd_down`
alert; starting it again clears it.

## Deliberately not here

Fan and pump RPM via `it87-dkms`: needs `acpi_enforce_resources=lax` as a kernel
parameter on this Gigabyte board. Dropped 2026-09-12, decision recorded on
COS-183. Do not re-propose it.

Remote alert delivery: decided against for now, the machine is attended. If it
comes back, `deliver()` is the only function that needs to change.

Prometheus with node_exporter, or Netdata: considered properly on COS-188 and
turned down. Both would cover the temperatures, the disks and the GPU, and
Prometheus can even express the idle floor as a subquery. Both answer by drawing
a graph, and the whole reason this exists is that the graphs never get looked at.
smartd was taken because it replaced four alerts that were reading the same byte
it reads. Do not re-propose the rest without a reason that is not "it is
standard".
