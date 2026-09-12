# AGENTS.md

## Board

Linear team `COS`, project **vitals**, area label `infra`.
Parent issue: COS-183. Related hardware issues: COS-182 (the AIO), COS-181 (UPS).
Read the `board` skill before touching any of it.

## Shape

One Python file, `vitals`, stdlib only, no dependencies. Two systemd timers:

- `vitals.timer` (user, every minute) runs `vitals check`. Does all the probing,
  thresholding, alerting and sample recording. Needs no privileges.
- `vitals-root.timer` (system, hourly) runs `vitals root-probe`. Exists only
  because NVMe SMART attributes need root. It does no thresholding — it dumps
  facts to `/var/lib/vitals/root.json` (0644) and the user half decides what they
  mean. Keeping all judgement in one place is deliberate.

`install.sh` symlinks rather than copies, so editing the repo changes what runs.

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

Keys in `alerts.json` that start with `_` are internal bookkeeping, not alerts;
the dispatch loop skips them when deciding what has recovered.

Two flags on `Alert` decide what happens to it, and both are carried through
`alerts.json` so the clear path can still see them:

- `event` - it happened rather than being true now (machine checks, NVRM
  failures, unsafe shutdowns, media errors). Fires once, no recovery notice.
- `emergency` - it is allowed to reach the desktop. Four alerts set it: SMART
  health, NVMe critical warning, spare exhausted, drive at its critical
  temperature. Everything else is logged silently and read back by `report`.

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

## Deliberately not here

Fan and pump RPM via `it87-dkms`: needs `acpi_enforce_resources=lax` as a kernel
parameter on this Gigabyte board. Dropped 2026-09-12, decision recorded on
COS-183. Do not re-propose it.

Remote alert delivery: decided against for now, the machine is attended. If it
comes back, `deliver()` is the only function that needs to change.
