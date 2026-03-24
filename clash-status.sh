#!/bin/sh
# clash-status.sh - test helper for validating Clash service status detection methods

set -u

SCRIPT_VERSION="0.1.1"
SERVICE_NAME="clash"
WATCH_SECS=0
INTERVAL=1
CWD_LOG="./clash-status-$(date +%Y%m%d-%H%M%S).log"

usage() {
  cat <<USAGE
Usage:
  $0 [--service clash] [--watch 60] [--interval 1]

Options:
  --service   Service name (default: clash)
  --watch     Watch mode duration in seconds (0 = one-shot)
  --interval  Poll interval in seconds for watch mode (default: 1)
  -h|--help   Show help
USAGE
}

log() {
  ts="$(date -Iseconds 2>/dev/null || date)"
  line="[$ts] $*"
  echo "$line"
  echo "$line" >> "$CWD_LOG"
}

probe_service_status() {
  raw="$(service "$SERVICE_NAME" status 2>&1)"
  rc_service=$?
  first="$(printf '%s\n' "$raw" | head -n1 | tr '[:upper:]' '[:lower:]')"

  # parser A: conservative negatives first
  a="unknown"
  case "$first" in
    *not*running*|*inactive*|*stopped*|*stop*|*dead*) a="off" ;;
    *running*|*started*|*active*) a="on" ;;
  esac

  # parser B: token check
  b="unknown"
  if printf '%s' "$first" | grep -Eq '(^|[^a-z])running([^a-z]|$)'; then
    b="on"
  fi
  if printf '%s' "$first" | grep -Eq 'not[[:space:]]+running|inactive|stopped|dead'; then
    b="off"
  fi

  # parser C: return code heuristic
  c="unknown"
  [ "$rc_service" -eq 0 ] && c="on"
  [ "$rc_service" -ne 0 ] && c="off"

  # parser D: tolerant typo heuristic (e.g. rlnning)
  d="unknown"
  if printf '%s' "$first" | grep -Eq 'r[a-z]nning|running|active|started'; then
    d="on"
  fi
  if printf '%s' "$first" | grep -Eq 'not[[:space:]]+running|inactive|stopped|dead'; then
    d="off"
  fi

  bytes="n/a"
  if command -v od >/dev/null 2>&1; then
    bytes="$(printf '%s' "$first" | od -An -tx1 | tr -s ' ' | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
  fi

  log "[service] rc=$rc_service raw_first='$first' bytes='$bytes' parserA=$a parserB=$b parserC=$c parserD=$d"
}

probe_initd_status() {
  if [ -x "/etc/init.d/$SERVICE_NAME" ]; then
    raw="$(/etc/init.d/$SERVICE_NAME status 2>&1)"
    rc_initd=$?
    first="$(printf '%s\n' "$raw" | head -n1 | tr '[:upper:]' '[:lower:]')"
    log "[init.d] rc=$rc_initd raw_first='$first'"
  else
    log "[init.d] /etc/init.d/$SERVICE_NAME not found"
  fi
}

probe_processes() {
  p1="$(pidof clash 2>/dev/null || true)"
  p2="$(pidof mihomo 2>/dev/null || true)"
  p3="$(ps w 2>/dev/null | grep -Ei '[c]lash|[m]ihomo' || true)"

  [ -n "$p1" ] && log "[pidof] clash=$p1" || log "[pidof] clash=none"
  [ -n "$p2" ] && log "[pidof] mihomo=$p2" || log "[pidof] mihomo=none"
  [ -n "$p3" ] && log "[ps] matched processes present" || log "[ps] no clash/mihomo process match"
}

probe_procd_ubus() {
  if command -v ubus >/dev/null 2>&1; then
    raw="$(ubus call service list '{"name":"'$SERVICE_NAME'"}' 2>/dev/null || true)"
    [ -n "$raw" ] && log "[ubus] service list returned payload" || log "[ubus] empty payload"
  else
    log "[ubus] command missing"
  fi
}

probe_ports() {
  if command -v ss >/dev/null 2>&1; then
    m="$(ss -lntup 2>/dev/null | grep -E ':(7890|7891|7892|7893|7894)\b' || true)"
    [ -n "$m" ] && log "[ports] ss matched 7890..7894" || log "[ports] no ss match for 7890..7894"
  else
    log "[ports] ss command missing"
  fi
}

combined_decision() {
  # heuristic summary from current probes
  srv="$(service "$SERVICE_NAME" status 2>&1 | head -n1 | tr '[:upper:]' '[:lower:]' || true)"
  p="$(ps w 2>/dev/null | grep -Ei '[c]lash|[m]ihomo' || true)"

  status="unknown"
  reason=""
  if printf '%s' "$srv" | grep -Eq 'not[[:space:]]+running|inactive|stopped|dead'; then
    status="off"; reason="service-status-negative"
  elif printf '%s' "$srv" | grep -Eq 'r[a-z]nning|running|started|active'; then
    status="on"; reason="service-status-positive"
  elif [ -n "$p" ]; then
    status="on"; reason="process-heuristic"
  fi

  log "[decision] status=$status reason=$reason"
}

run_once() {
  log "--- clash-status probe start (service=$SERVICE_NAME, version=$SCRIPT_VERSION) ---"
  probe_service_status
  probe_initd_status
  probe_processes
  probe_procd_ubus
  probe_ports
  combined_decision
  log "--- clash-status probe end ---"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --service) SERVICE_NAME="${2:-}"; shift 2 ;;
      --watch) WATCH_SECS="${2:-0}"; shift 2 ;;
      --interval) INTERVAL="${2:-1}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done
}

main() {
  parse_args "$@"
  log "log_file=$CWD_LOG"

  if [ "$WATCH_SECS" -le 0 ]; then
    run_once
    exit 0
  fi

  elapsed=0
  while [ "$elapsed" -lt "$WATCH_SECS" ]; do
    log "watch progress: ${elapsed}/${WATCH_SECS}s"
    run_once
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
  done
}

main "$@"
