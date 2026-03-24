# openwrt-routing-diagnostic

Read-only diagnostic toolkit for OpenWRT routing issues (Mihomo/Clash TPROXY + Tailscale).

## Script

`owrt-diag.sh` collects system/network snapshots for comparison between:
- `Clash_ON`
- `Clash_OFF`

### Usage

```bash
./owrt-diag.sh --mode Clash_ON
./owrt-diag.sh --mode Clash_OFF --out /tmp/owrt-diagnostic
./owrt-diag.sh --mode Clash_OFF --no-anon
```

Artifacts are written to:

```text
/tmp/owrt-diagnostic/<session_id>/
  ├─ raw/
  │   ├─ 00_static/
  │   └─ 10_mode_Clash_OFF|11_mode_Clash_ON/
  ├─ anon/
  └─ meta/   # includes 90_manifest, 91_errors, 93_matrix, 95_events, 96_summary
```
