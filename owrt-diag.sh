#!/bin/sh
# owrt-diag.sh - read-only OpenWRT diagnostic collector for Clash/Mihomo + Tailscale scenarios

set -u

SCRIPT_VERSION="0.1.0"
OUT_BASE_DEFAULT="/tmp/owrt-diagnostic"
MIN_FREE_KB_HARD="8192"
MIN_FREE_KB_SOFT="32768"
MODE=""
OUT_BASE="$OUT_BASE_DEFAULT"
NO_ANON=0
SESSION_ID=""
HOSTNAME_SHORT="$(hostname 2>/dev/null || echo unknown)"

STATUS_OK=0
STATUS_WARN=0
STATUS_FAIL=0
DEGRADED=0

usage() {
  cat <<USAGE
Usage:
  $0 --mode Clash_ON|Clash_OFF [--out /tmp/owrt-diagnostic] [--no-anon]

Options:
  --mode      Required. Clash_ON or Clash_OFF.
  --out       Output base directory (default: $OUT_BASE_DEFAULT)
  --no-anon   Skip anonymized copies (raw data only)
  -h|--help   Show help
USAGE
}

log_event() {
  ts="$(date -Iseconds 2>/dev/null || date)"
  echo "[$ts] $*" >> "$EVENTS_LOG"
}

record_error() {
  sec="$1"; code="$2"; msg="$3"
  ts="$(date -Iseconds 2>/dev/null || date)"
  echo "[$ts] [$sec] [$code] $msg" >> "$ERRORS_LOG"
  STATUS_FAIL=$((STATUS_FAIL + 1))
}

record_warn() {
  sec="$1"; msg="$2"
  ts="$(date -Iseconds 2>/dev/null || date)"
  echo "[$ts] [$sec] [WARN] $msg" >> "$ERRORS_LOG"
  STATUS_WARN=$((STATUS_WARN + 1))
}

append_matrix() {
  file="$1"; cmd="$2"; status="$3"; rc="$4"
  ts="$(date -Iseconds 2>/dev/null || date)"
  printf '%s,%s,%s,%s,%s\n' "$ts" "$file" "$status" "$rc" "$cmd" >> "$MATRIX_LOG"
}

init_log_file() {
  f="$1"
  section="$2"
  ts="$(date -Iseconds 2>/dev/null || date)"
  {
    echo "### owrt-diag section"
    echo "SECTION: $section"
    echo "MODE: $MODE"
    echo "SESSION_ID: $SESSION_ID"
    echo "HOSTNAME: $HOSTNAME_SHORT"
    echo "SCRIPT_VERSION: $SCRIPT_VERSION"
    echo "GENERATED_AT: $ts"
    echo
  } > "$f"
}

mask_sensitive_data() {
  in="$1"; out="$2"
  sed -E \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP_REDACTED]/g' \
    -e 's/([0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}/[IPV6_REDACTED]/g' \
    -e 's/([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}/[MAC_REDACTED]/g' \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[UUID_REDACTED]/g' \
    -e 's/(password|passwd|secret|token|apikey|api_key)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=[SECRET_REDACTED]/Ig' \
    "$in" > "$out" 2>/dev/null || return 1
  return 0
}

run_and_capture() {
  section="$1"; outfile="$2"; shift 2
  cmd="$*"
  tmp_err="${outfile}.stderr.tmp"
  ts="$(date -Iseconds 2>/dev/null || date)"

  {
    echo "===== BEGIN COMMAND ====="
    echo "CMD: $cmd"
    echo "SECTION: $section"
    echo "TIME: $ts"
    if command -v timeout >/dev/null 2>&1; then
      timeout 15s sh -c "$cmd" > "${outfile}.stdout.tmp" 2> "$tmp_err"
      rc=$?
    else
      sh -c "$cmd" > "${outfile}.stdout.tmp" 2> "$tmp_err"
      rc=$?
    fi
    echo "RC: $rc"
    echo "----- STDOUT -----"
    cat "${outfile}.stdout.tmp" 2>/dev/null
    echo "----- STDERR -----"
    cat "$tmp_err" 2>/dev/null
    echo "===== END COMMAND ====="
    echo
  } >> "$outfile"

  rm -f "${outfile}.stdout.tmp" "$tmp_err"

  if [ "$rc" -eq 0 ]; then
    append_matrix "$outfile" "$cmd" "OK" "$rc"
    STATUS_OK=$((STATUS_OK + 1))
  else
    append_matrix "$outfile" "$cmd" "WARN" "$rc"
    record_warn "$section" "command failed rc=$rc: $cmd"
  fi
}

check_missing_commands() {
  missing=""
  for c in ip nft fw4 uci ubus logread sed awk grep; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing="$missing $c"
      echo "missing_command=$c" >> "$RECO_LOG"
    fi
  done
  if [ -n "$missing" ]; then
    record_warn "preflight" "missing commands:$missing"
  fi
}

detect_pkg_manager() {
  if command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v opkg >/dev/null 2>&1; then
    echo "opkg"
  else
    echo "unknown"
  fi
}

preflight_space_guard() {
  avail_kb="$(df -k "$OUT_BASE" 2>/dev/null | awk 'NR==2 {print $4}')"
  [ -n "$avail_kb" ] || avail_kb=0

  if [ "$avail_kb" -lt "$MIN_FREE_KB_HARD" ]; then
    record_error "preflight" "E_SPACE" "available=${avail_kb}KB < hard=${MIN_FREE_KB_HARD}KB"
    echo "ERROR: not enough space in $OUT_BASE (${avail_kb}KB)." >&2
    return 1
  fi

  if [ "$avail_kb" -lt "$MIN_FREE_KB_SOFT" ]; then
    DEGRADED=1
    log_event "degraded mode enabled: low space ${avail_kb}KB"
    record_warn "preflight" "low space, degraded mode enabled (${avail_kb}KB)"
  fi

  return 0
}

collect_static() {
  f="$STATIC_DIR/01_system_baseline.log"
  init_log_file "$f" "system_baseline"
  run_and_capture "system" "$f" "uname -a"
  run_and_capture "system" "$f" "cat /etc/openwrt_release 2>/dev/null"
  run_and_capture "system" "$f" "cat /etc/os-release 2>/dev/null"
  run_and_capture "system" "$f" "ubus call system board 2>/dev/null"
  run_and_capture "system" "$f" "uptime"
  run_and_capture "system" "$f" "free -h"
  run_and_capture "system" "$f" "df -h"

  f="$STATIC_DIR/02_packages_and_binaries.log"
  init_log_file "$f" "packages_and_binaries"
  pm="$(detect_pkg_manager)"
  run_and_capture "packages" "$f" "echo package_manager=$pm"
  if [ "$pm" = "opkg" ]; then
    run_and_capture "packages" "$f" "opkg list-installed"
  elif [ "$pm" = "apk" ]; then
    run_and_capture "packages" "$f" "apk info -vv"
  else
    record_warn "packages" "No package manager detected"
  fi
  run_and_capture "packages" "$f" "which nft ip iptables ip6tables fw4 tailscale mihomo clash logread ubus uci 2>&1"

  f="$STATIC_DIR/03_kernel_modules.log"
  init_log_file "$f" "kernel_modules"
  run_and_capture "modules" "$f" "lsmod"
  run_and_capture "modules" "$f" "modinfo nft_tproxy 2>/dev/null || true"
  run_and_capture "modules" "$f" "modinfo nf_tproxy_ipv4 2>/dev/null || true"
  run_and_capture "modules" "$f" "modinfo nf_tproxy_ipv6 2>/dev/null || true"
  run_and_capture "modules" "$f" "modinfo nft_socket 2>/dev/null || true"

  f="$STATIC_DIR/04_uci_network_firewall_dhcp_system.log"
  init_log_file "$f" "uci_exports"
  run_and_capture "uci" "$f" "uci export network"
  run_and_capture "uci" "$f" "uci export firewall"
  run_and_capture "uci" "$f" "uci export dhcp"
  run_and_capture "uci" "$f" "uci export system"
}

collect_mode_runtime() {
  f="$MODE_DIR/11_interfaces_runtime.log"
  init_log_file "$f" "interfaces_runtime"
  run_and_capture "interfaces" "$f" "ip -br link"
  run_and_capture "interfaces" "$f" "ip -br addr"
  run_and_capture "interfaces" "$f" "ip -d link"
  run_and_capture "interfaces" "$f" "ip link show clash-tun 2>&1"
  run_and_capture "interfaces" "$f" "ubus call network.interface dump 2>/dev/null"

  f="$MODE_DIR/12_routing_runtime.log"
  init_log_file "$f" "routing_runtime"
  run_and_capture "routing" "$f" "ip route show table main"
  run_and_capture "routing" "$f" "ip route show table all"
  run_and_capture "routing" "$f" "ip route show table 100"
  run_and_capture "routing" "$f" "ip route show table 101"
  run_and_capture "routing" "$f" "ip rule show"
  run_and_capture "routing" "$f" "ip rule show | grep -E 'fwmark|lookup 100|lookup 101'"
  run_and_capture "routing" "$f" "ip -6 route show table all"
  run_and_capture "routing" "$f" "ip -6 rule show"

  f="$MODE_DIR/13_fw4_nft_runtime.log"
  init_log_file "$f" "fw4_nft_runtime"
  run_and_capture "firewall" "$f" "fw4 print"
  run_and_capture "firewall" "$f" "nft list tables"
  run_and_capture "firewall" "$f" "nft list ruleset"
  run_and_capture "firewall" "$f" "nft -a list ruleset"
  run_and_capture "firewall" "$f" "nft list ruleset | grep -Ei 'tproxy|mark|7894|clash|quic|443'"

  f="$MODE_DIR/14_iptables_compat_audit.log"
  init_log_file "$f" "iptables_compat"
  run_and_capture "iptables" "$f" "iptables -V 2>&1"
  run_and_capture "iptables" "$f" "ip6tables -V 2>&1"
  run_and_capture "iptables" "$f" "iptables -t mangle -S 2>&1"
  run_and_capture "iptables" "$f" "iptables -t filter -S 2>&1"
  run_and_capture "iptables" "$f" "iptables-save -t mangle 2>&1"
  run_and_capture "iptables" "$f" "iptables-save 2>&1"
  run_and_capture "iptables" "$f" "ip6tables-save 2>&1"

  f="$MODE_DIR/15_dns_runtime.log"
  init_log_file "$f" "dns_runtime"
  run_and_capture "dns" "$f" "cat /tmp/resolv.conf 2>/dev/null"
  run_and_capture "dns" "$f" "cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null"
  run_and_capture "dns" "$f" "uci export dhcp"
  run_and_capture "dns" "$f" "logread | tail -n 300 | grep -Ei 'dns|resolve|dnsmasq|servfail|timeout'"
  run_and_capture "dns" "$f" "nslookup openwrt.org 127.0.0.1 2>&1 || true"

  f="$MODE_DIR/16_clash_tailscale_runtime.log"
  init_log_file "$f" "clash_tailscale_runtime"
  run_and_capture "runtime" "$f" "ps w | grep -Ei 'mihomo|clash|tailscale|tun|tproxy'"
  run_and_capture "runtime" "$f" "ss -lntup"
  run_and_capture "runtime" "$f" "ss -lntup | grep -E '7890|7891|7892|7893|7894' || true"
  run_and_capture "runtime" "$f" "tailscale status 2>&1 || true"
  run_and_capture "runtime" "$f" "tailscale ip -4 2>&1 || true"

  f="$MODE_DIR/17_sysctl_network_runtime.log"
  init_log_file "$f" "sysctl_runtime"
  run_and_capture "sysctl" "$f" "sysctl net.ipv4.ip_forward"
  run_and_capture "sysctl" "$f" "sysctl net.ipv6.conf.all.forwarding"
  run_and_capture "sysctl" "$f" "sysctl net.ipv4.conf.all.rp_filter"
  run_and_capture "sysctl" "$f" "sysctl net.ipv4.conf.default.rp_filter"

  f="$MODE_DIR/18_logs_filtered.log"
  init_log_file "$f" "logs_filtered"
  if [ "$DEGRADED" -eq 1 ]; then
    run_and_capture "logs" "$f" "logread | tail -n 200"
  else
    run_and_capture "logs" "$f" "logread | tail -n 800"
  fi
  run_and_capture "logs" "$f" "dmesg | tail -n 300"
  run_and_capture "logs" "$f" "logread | grep -Ei 'nft|fw4|tproxy|tailscale|dns|drop|reject|conntrack' | tail -n 500"

  f="$MODE_DIR/19_router_connectivity.log"
  init_log_file "$f" "router_connectivity"
  run_and_capture "connectivity" "$f" "ping -c 3 1.1.1.1"
  run_and_capture "connectivity" "$f" "ping -c 3 8.8.8.8"
  run_and_capture "connectivity" "$f" "nslookup openwrt.org 1.1.1.1 2>&1 || true"

  f="$MODE_DIR/20_ipset_runtime.log"
  init_log_file "$f" "ipset_runtime"
  run_and_capture "ipset" "$f" "ipset list clash_fakeip_whitelist 2>&1"
  run_and_capture "ipset" "$f" "ipset list 2>&1"
}

make_anonymous_copy() {
  [ "$NO_ANON" -eq 1 ] && return 0
  log_event "start anonymization"
  find "$RAW_ROOT" -type f | while read -r src; do
    rel="${src#$RAW_ROOT/}"
    dst="$ANON_ROOT/$rel"
    mkdir -p "$(dirname "$dst")"
    if ! mask_sensitive_data "$src" "$dst"; then
      record_warn "anon" "failed to anonymize $src"
    fi
  done
}

write_manifest() {
  {
    echo "script_version=$SCRIPT_VERSION"
    echo "mode=$MODE"
    echo "session_id=$SESSION_ID"
    echo "hostname=$HOSTNAME_SHORT"
    echo "output_base=$OUT_BASE"
    echo "degraded=$DEGRADED"
    echo "status_ok=$STATUS_OK"
    echo "status_warn=$STATUS_WARN"
    echo "status_fail=$STATUS_FAIL"
    echo "timestamp=$(date -Iseconds 2>/dev/null || date)"
  } >> "$MANIFEST_LOG"
}

write_summary() {
  {
    echo "summary_ok=$STATUS_OK"
    echo "summary_warn=$STATUS_WARN"
    echo "summary_fail=$STATUS_FAIL"
    if [ "$STATUS_FAIL" -gt 0 ]; then
      echo "summary_result=FAIL"
    elif [ "$STATUS_WARN" -gt 0 ]; then
      echo "summary_result=WARN"
    else
      echo "summary_result=OK"
    fi
  } > "$SUMMARY_LOG"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)
        MODE="${2:-}"; shift 2 ;;
      --out)
        OUT_BASE="${2:-}"; shift 2 ;;
      --no-anon)
        NO_ANON=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 2 ;;
    esac
  done

  if [ "$MODE" != "Clash_ON" ] && [ "$MODE" != "Clash_OFF" ]; then
    echo "--mode must be Clash_ON or Clash_OFF" >&2
    usage
    exit 2
  fi
}

main() {
  parse_args "$@"

  mkdir -p "$OUT_BASE" || {
    echo "Cannot create output dir: $OUT_BASE" >&2
    exit 2
  }

  SESSION_ID="$(date +%Y%m%d-%H%M%S)_${HOSTNAME_SHORT}"
  ROOT_DIR="$OUT_BASE/$SESSION_ID"
  RAW_ROOT="$ROOT_DIR/raw"
  ANON_ROOT="$ROOT_DIR/anon"
  META_DIR="$ROOT_DIR/meta"
  STATIC_DIR="$RAW_ROOT/00_static"
  if [ "$MODE" = "Clash_OFF" ]; then
    MODE_DIR="$RAW_ROOT/10_mode_Clash_OFF"
  else
    MODE_DIR="$RAW_ROOT/11_mode_Clash_ON"
  fi

  mkdir -p "$STATIC_DIR" "$MODE_DIR" "$META_DIR" "$ANON_ROOT" || exit 2

  MANIFEST_LOG="$META_DIR/90_manifest.log"
  ERRORS_LOG="$META_DIR/91_errors.log"
  RECO_LOG="$META_DIR/92_recommendations.log"
  MATRIX_LOG="$META_DIR/93_collection_matrix.csv"
  EVENTS_LOG="$META_DIR/95_runtime_events.log"
  SUMMARY_LOG="$META_DIR/96_summary.log"

  touch "$MANIFEST_LOG" "$ERRORS_LOG" "$RECO_LOG" "$MATRIX_LOG" "$EVENTS_LOG" "$SUMMARY_LOG" || exit 2
  log_event "session started"

  if ! preflight_space_guard; then
    write_manifest
    write_summary
    exit 2
  fi

  check_missing_commands
  collect_static
  collect_mode_runtime
  make_anonymous_copy
  write_manifest
  write_summary

  log_event "session finished"

  if [ "$STATUS_FAIL" -gt 0 ]; then
    exit 2
  elif [ "$STATUS_WARN" -gt 0 ]; then
    exit 1
  else
    exit 0
  fi
}

main "$@"
