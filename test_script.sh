#!/bin/sh
# test_script.sh - lightweight playground for logic before integrating into owrt-diag.sh

set -u

sanitize_hostname() {
  raw="$1"
  safe="$(printf '%s' "$raw" | LC_ALL=C tr -cd '[:alnum:]._-')"
  safe="$(printf '%s' "$safe" | sed 's/[._-][._-]*/_/g; s/^_\+//; s/_\+$//')"
  case "$safe" in
    ""|"."|".."|"-") echo "_unknown" ;;
    *) echo "$safe" ;;
  esac
}

parse_status_line() {
  line="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$line" | grep -Eq 'not[[:space:]]+running|inactive|stopped|dead'; then
    echo "off"
  elif printf '%s' "$line" | grep -Eq 'r[a-z]nning|running|active|started'; then
    echo "on"
  else
    echo "unknown"
  fi
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

case "${1:-all}" in
  hostname) run_hostname_tests ;;
  status) run_status_tests ;;
  all)
    run_hostname_tests
    echo
    run_status_tests
    ;;
  *)
    echo "Usage: $0 [hostname|status|all]" >&2
    exit 2
    ;;
esac
