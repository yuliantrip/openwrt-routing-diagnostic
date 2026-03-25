#!/bin/sh
# clash-checker.sh - candidate status decision logic for future integration into owrt-diag.sh

set -u

SCRIPT_VERSION="0.1.0"
SERVICE_NAME="clash"
WATCH_SECS=0
INTERVAL=2
LOG_FILE="./clash-checker-$(date +%Y%m%d-%H%M%S).log"

usage() {
  cat <<USAGE
Usage:
  $0 [--service clash] [--watch 60] [--interval 2]

Options:
  --service   Service name to check (default: clash)
  --watch     Repeat checks for N seconds (default: 0, one-shot)
  --interval  Seconds between checks in watch mode (default: 2)
  -h|--help   Show help
USAGE
}

log() {
  ts="$(date -Iseconds 2>/dev/null || date)"
  line="[$ts] $*"
  echo "$line"
  echo "$line" >> "$LOG_FILE"
}

probe_service() {
  raw_service="$(service "$SERVICE_NAME" status 2>&1)"
  rc_service=$?
  first_service="$(printf '%s\n' "$raw_service" | head -n1 | tr '[:upper:]' '[:lower:]')"

  parser_service="unknown"
  if printf '%s' "$first_service" | grep -Eq 'not[[:space:]]+running|inactive|stopped|dead'; then
    parser_service="off"
  elif printf '%s' "$first_service" | grep -Eq 'r[a-z]nning|running|active|started'; then
    parser_service="on"
  fi

  log "[service] rc=$rc_service first='$first_service' parser=$parser_service"
}

probe_initd() {
  if [ -x "/etc/init.d/$SERVICE_NAME" ]; then
    raw_initd="$(/etc/init.d/$SERVICE_NAME status 2>&1)"
    rc_initd=$?
    first_initd="$(printf '%s\n' "$raw_initd" | head -n1 | tr '[:upper:]' '[:lower:]')"

    parser_initd="unknown"
    if printf '%s' "$first_initd" | grep -Eq 'not[[:space:]]+running|inactive|stopped|dead'; then
      parser_initd="off"
    elif printf '%s' "$first_initd" | grep -Eq 'r[a-z]nning|running|active|started'; then
      parser_initd="on"
    fi
    log "[initd] rc=$rc_initd first='$first_initd' parser=$parser_initd"
  else
    rc_initd=255
    parser_initd="unknown"
    log "[initd] /etc/init.d/$SERVICE_NAME not found"
  fi
}

probe_processes() {
  pid_clash="$(pidof clash 2>/dev/null || true)"
  pid_mihomo="$(pidof mihomo 2>/dev/null || true)"
  ps_match="$(ps w 2>/dev/null | grep -Ei '[c]lash|[m]ihomo' || true)"

  proc_on=0
  [ -n "$pid_clash" ] && proc_on=1
  [ -n "$pid_mihomo" ] && proc_on=1
  [ -n "$ps_match" ] && proc_on=1

  log "[proc] pid_clash='${pid_clash:-none}' pid_mihomo='${pid_mihomo:-none}' proc_on=$proc_on"
}

probe_ports() {
  port_on=0
  if command -v ss >/dev/null 2>&1; then
    ss_match="$(ss -lntup 2>/dev/null | grep -E ':(7890|7891|7892|7893|7894)\b' || true)"
    [ -n "$ss_match" ] && port_on=1
    log "[ports] ss_789x=$port_on"
  else
    log "[ports] ss missing"
  fi
}

decide_status() {
  final_status="unknown"
  reason=""

  # Positive strong signal: service/initd reports ON
  if [ "$parser_service" = "on" ] || [ "$parser_initd" = "on" ]; then
    if [ "$proc_on" -eq 1 ] || [ "$port_on" -eq 1 ]; then
      final_status="on"
      reason="service-or-initd-on + process/port confirmation"
    else
      final_status="transition"
      reason="service-or-initd-on but no process/port confirmation"
    fi

  # Negative strong signal: service/initd reports OFF
  elif [ "$parser_service" = "off" ] || [ "$parser_initd" = "off" ]; then
    if [ "$proc_on" -eq 0 ] && [ "$port_on" -eq 0 ]; then
      final_status="off"
      reason="service-or-initd-off + no process/port"
    else
      final_status="transition"
      reason="service-or-initd-off but process/port still present"
    fi

  # Fallback: no service clarity
  else
    if [ "$proc_on" -eq 1 ] || [ "$port_on" -eq 1 ]; then
      final_status="on"
      reason="fallback process/port heuristic"
    else
      final_status="unknown"
      reason="no reliable signals"
    fi
  fi

  log "[decision] final_status=$final_status reason='$reason'"
}

run_once() {
  log "--- clash-checker start (service=$SERVICE_NAME, version=$SCRIPT_VERSION) ---"
  probe_service
  probe_initd
  probe_processes
  probe_ports
  decide_status
  log "--- clash-checker end ---"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --service) SERVICE_NAME="${2:-}"; shift 2 ;;
      --watch) WATCH_SECS="${2:-0}"; shift 2 ;;
      --interval) INTERVAL="${2:-2}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done
}

main() {
  parse_args "$@"
  log "log_file=$LOG_FILE"

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
