# openwrt-routing-diagnostic

Read-only-first diagnostic toolkit for OpenWRT routing issues (Mihomo/Clash TPROXY + Tailscale).

## Shell compatibility

Script is written for `/bin/sh` (BusyBox `ash` compatible), not bash-specific syntax.

## Default tuning in script header

All default runtime/anonymization knobs are grouped at the top of `owrt-diag.sh` under `# Default settings (editable)`:
- output path / ssclash path defaults
- timeout and service wait values
- log tail sizes for normal/degraded mode
- anonymization policy switches and prefixes

## Script

`owrt-diag.sh` collects system/network snapshots and writes artifacts to:

```text
/tmp/owrt-diagnostic/<session_id>/
  ├─ raw/
  │   ├─ 00_static/
  │   ├─ 10_mode_Clash_OFF/
  │   ├─ 11_mode_Clash_ON/
  │   └─ 12_mode_Clash_ON_post/   # only in --auto when initial state is ON
  ├─ anon/
  └─ meta/
```

## Usage

```bash
# default run (no params): detect service clash status and run one snapshot
./owrt-diag.sh

# manual mode
./owrt-diag.sh --clash on
./owrt-diag.sh --clash off --out /tmp/owrt-diagnostic

# auto workflow with stop/start checks and state restore
./owrt-diag.sh --auto

# optional ssclash sources
./owrt-diag.sh --ssclash-dir /opt/clash/bin
./owrt-diag.sh --ssclash-file /opt/clash/bin/clash-rules

# raw only
./owrt-diag.sh --no-anon
```

## Default parameters

Running `./owrt-diag.sh` without extra options uses:
- auto-detected clash state via `service clash status`
- output directory: `/tmp/owrt-diagnostic`
- ssclash directory: `/opt/clash/bin`
- anonymization: enabled

## Anonymization policy (anon/)

- Loopback IPv4 (`127.x.x.x`) is preserved.
- Private/CGNAT ranges are rewritten to `55.55.<octet3>.<octet4>` (keeps relation, hides real subnet).
- Public IPv4 are deterministically remapped into `198.18.x.y` (same source IP => same anonymized IP).
- MAC addresses are partially masked: `XX:XX:XX:XX:<last2octets>`.
- `option username`, `option password`, token/secret-like values are masked.

## Metadata files

- `meta/90_manifest.log`
- `meta/91_errors.log`
- `meta/92_recommendations.log`
- `meta/93_collection_matrix.csv`
- `meta/94_ssclash_touchpoints.log`
- `meta/95_runtime_events.log`
- `meta/96_summary.log`
- `meta/97_run_<timestamp>.log`
