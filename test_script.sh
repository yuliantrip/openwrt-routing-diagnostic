#!/bin/sh
# test_script.sh - lightweight playground for logic before integrating into owrt-diag.sh

set -u

sanitize_hostname() {
  raw="$1"
  # BusyBox tr/locale combinations can behave unexpectedly with POSIX classes.
  # Use sed with explicit ASCII allowlist for predictable output.
  safe="$(printf '%s' "$raw" | sed 's/[^A-Za-z0-9._-]/_/g')"
  safe="$(printf '%s' "$safe" | sed 's/[._-][._-]*/_/g; s/^_\+//; s/_\+$//')"
  case "$safe" in
    ""|"."|".."|"-") echo "_unknown" ;;
    *) echo "$safe" ;;
  esac
}

parse_status_line() {
  line="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$line" in
    *not\ running*|*inactive*|*stopped*|*dead*) echo "off" ;;
    *running*|*r?nning*|*active*|*started*) echo "on" ;;
    *) echo "unknown" ;;
  esac
}

run_hostname_tests() {
  cat <<'CASES' | while IFS= read -r s; do
Славик-Cudy
router.home
  weird   spaces
__la___-_u__
...

CASES
    out="$(sanitize_hostname "$s")"
    printf "in='%s' -> out='%s'\n" "$s" "$out"
  done
}

run_status_tests() {
  cat <<'CASES' | while IFS= read -r s; do
running
rlnning
inactive
not running
started
???
CASES
    out="$(parse_status_line "$s")"
    printf "status='%s' -> parsed='%s'\n" "$s" "$out"
  done
}

run_live_system_tests() {
  service_name="${1:-clash}"
  echo "== live system probes =="

  if command -v hostname >/dev/null 2>&1; then
    h="$(hostname 2>/dev/null || true)"
    printf "live hostname='%s' -> sanitized='%s'\n" "$h" "$(sanitize_hostname "$h")"
  else
    echo "hostname command missing"
  fi

  if command -v service >/dev/null 2>&1; then
    first="$(service "$service_name" status 2>&1 | head -n1)"
    printf "service %s status first_line='%s' -> parsed='%s'\n" \
      "$service_name" "$first" "$(parse_status_line "$first")"
  else
    echo "service command missing"
  fi
}

case "${1:-all}" in
  hostname) run_hostname_tests ;;
  status) run_status_tests ;;
  live) run_live_system_tests "${2:-clash}" ;;
  all)
    run_hostname_tests
    echo
    run_status_tests
    echo
    run_live_system_tests "${2:-clash}"
    ;;
  *)
    echo "Usage: $0 [hostname|status|live [service]|all [service]]" >&2
    exit 2
    ;;
esac
