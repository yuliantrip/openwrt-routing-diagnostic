#!/bin/sh
# owrt-diag.sh - OpenWRT diagnostic collector (manual + auto Clash state workflow)

set -u

SCRIPT_VERSION="0.3.7"

# =========================
# Default settings (editable)
# =========================
OUT_BASE_DEFAULT="/tmp/owrt-diagnostic"   # base output directory
SSCLASH_DIR_DEFAULT="/opt/clash/bin"      # default path to clash-rules scripts
CLASH_SERVICE_NAME="clash"                # init service name (clash/mihomo/etc)

MIN_FREE_KB_HARD="8192"                   # hard stop threshold for free space (KB)
MIN_FREE_KB_SOFT="32768"                  # degraded mode threshold for free space (KB)
CMD_TIMEOUT_SEC="15"                      # timeout for diagnostic commands
SERVICE_CMD_TIMEOUT_SEC="60"              # timeout for `service clash start/stop` command itself
SERVICE_WAIT_MAX_SEC="60"                 # max seconds waiting until service reaches target state
SERVICE_WAIT_LOG_INTERVAL_SEC="1"         # progress log interval while waiting service state
LOG_TAIL_NORMAL="800"                     # log tail lines in normal mode
LOG_TAIL_DEGRADED="200"                   # log tail lines in degraded mode
DNS_TAIL_LINES="300"                      # dns log tail lines

ANON_PRIVATE_PREFIX="55.55"               # private/CGNAT => 55.55.<oct3>.<oct4>
ANON_PUBLIC_PREFIX="198.18"               # public IP deterministic pool
ANON_MASK_IPV6=1                          # 1=mask IPv6
ANON_MASK_UUID=1                          # 1=mask UUID
ANON_MASK_USERPASS=1                      # 1=mask usernames/passwords/tokens
ANON_MASK_MAC_PARTIAL=1                   # 1=mask MAC partially

# Runtime variables
OUT_BASE="$OUT_BASE_DEFAULT"
NO_ANON=0
SESSION_ID=""
HOSTNAME_SHORT="$(hostname 2>/dev/null || echo unknown)"
SSCLASH_DIR="$SSCLASH_DIR_DEFAULT"
SSCLASH_FILE=""
AUTO_MODE=0
REQUESTED_CLASH=""  # on|off
MODE=""

STATUS_OK=0
STATUS_WARN=0
STATUS_FAIL=0
DEGRADED=0

usage() {
  cat <<USAGE
Usage:
  $0 [--clash on|off] [--auto] [--out $OUT_BASE_DEFAULT] [--ssclash-dir $SSCLASH_DIR_DEFAULT] [--ssclash-file /path/to/clash-rules.sh] [--no-anon]

Options:
  --clash         Manual target mode: on/off
  --auto          Automatic two-state workflow with service start/stop and restore initial state
  --out           Output base directory (default: $OUT_BASE_DEFAULT)
  --ssclash-dir   Directory with clash-rules scripts (default: $SSCLASH_DIR_DEFAULT)
  --ssclash-file  Exact path to clash-rules script (overrides --ssclash-dir)
  --no-anon       Skip anonymized copies (raw only)
  -h|--help       Show help

Defaults without parameters:
  - Detects current clash service state and runs one diagnostic snapshot for detected state.
USAGE
}

sanitize_hostname() {
  raw="$1"

  # BusyBox tr/locale combinations can behave unexpectedly with POSIX classes.
  # Use sed with explicit ASCII allowlist for predictable output.
  safe="$(printf '%s' "$raw" | sed 's/[^A-Za-z0-9._-]/_/g')"
  # Collapse repeating separators and trim edges.
  safe="$(printf '%s' "$safe" | sed 's/[._-][._-]*/_/g; s/^_\\+//; s/_\\+$//')"
  # Avoid single separator/dot values.
  case "$safe" in
    ""|"."|".."|"-") echo "_unknown" ;;
    *) echo "$safe" ;;
  esac
}

detect_hostname() {
  h="$(hostname 2>/dev/null || true)"
  [ -z "$h" ] && h="$(cat /proc/sys/kernel/hostname 2>/dev/null || true)"
  [ -z "$h" ] && h="$(uname -n 2>/dev/null || true)"
  [ -z "$h" ] && h="_unknown"
  sanitize_hostname "$h"
}

fname() {
  # $1 = logical base name without extension
  echo "${1}_${HOSTNAME_SHORT}.log"
}

say() {
  level="$1"; shift
  ts="$(date -Iseconds 2>/dev/null || date)"
  msg="[$ts] [$level] $*"
  echo "$msg"
  [ -n "${RUN_LOG:-}" ] && echo "$msg" >> "$RUN_LOG"
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
  say "ERROR" "$sec: $code: $msg"
}

record_warn() {
  sec="$1"; msg="$2"
  ts="$(date -Iseconds 2>/dev/null || date)"
  echo "[$ts] [$sec] [WARN] $msg" >> "$ERRORS_LOG"
  STATUS_WARN=$((STATUS_WARN + 1))
  say "WARN" "$sec: $msg"
}

append_matrix() {
  file="$1"; cmd="$2"; status="$3"; rc="$4"
  ts="$(date -Iseconds 2>/dev/null || date)"
  printf '%s,%s,%s,%s,%s\n' "$ts" "$file" "$status" "$rc" "$cmd" >> "$MATRIX_LOG"
}

init_log_file() {
  f="$1"; section="$2"
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
  map_append="${ANON_MAP_FILE}.append.$$"
  awk -v priv_pref="$ANON_PRIVATE_PREFIX" -v pub_pref="$ANON_PUBLIC_PREFIX" \
      -v mask_ipv6="$ANON_MASK_IPV6" -v mask_uuid="$ANON_MASK_UUID" \
      -v mask_userpass="$ANON_MASK_USERPASS" -v mask_mac_partial="$ANON_MASK_MAC_PARTIAL" \
      -v map_file="$ANON_MAP_FILE" -v map_append="$map_append" '
    BEGIN {
      while ((getline line_map < map_file) > 0) {
        split(line_map, kv, "\t");
        if (kv[1] != "" && kv[2] != "") {
          pub_map[kv[1]] = kv[2];
          pub_count++;
        }
      }
      close(map_file);
    }
    function is_private(a,b,c,d) {
      if (a==127) return 2;                   # loopback, keep as-is
      if (a==10) return 1;
      if (a==192 && b==168) return 1;
      if (a==172 && b>=16 && b<=31) return 1;
      if (a==100 && b>=64 && b<=127) return 1; # CGNAT/Tailscale-like
      return 0;
    }
    function map_ipv4(ip,    a,b,c,d,kind,p1,p2) {
      split(ip,o,"."); a=o[1]+0; b=o[2]+0; c=o[3]+0; d=o[4]+0;
      kind=is_private(a,b,c,d);
      if (kind==2) return ip; # loopback
      if (kind==1) return priv_pref "." c "." d;
      if (!(ip in pub_map)) {
        pub_count++;
        p1=pub_pref; split(p1,pp,".");
        pub_map[ip]=pp[1] "." pp[2] "." int((pub_count-1)/254) "." ((pub_count-1)%254+1);
        print ip "\t" pub_map[ip] >> map_append;
      }
      return pub_map[ip];
    }
    function mask_mac(mac, m) {
      split(mac,m,":");
      return "XX:XX:XX:XX:" m[5] ":" m[6];
    }
    {
      line=$0;

      if (mask_uuid == 1)
        gsub(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/, "[UUID_REDACTED]", line);
      if (mask_userpass == 1) {
        gsub(/option[ \t]+username[ \t]+'\047[^'\047]*\047/, "option username '\''[USER_REDACTED]'\''", line);
        gsub(/option[ \t]+password[ \t]+'\047[^'\047]*\047/, "option password '\''[SECRET_REDACTED]'\''", line);
        gsub(/option[ \t]+token[ \t]+'\047[^'\047]*\047/, "option token '\''[SECRET_REDACTED]'\''", line);
        gsub(/(password|passwd|secret|token|apikey|api_key)[ \t]*[:=][ \t]*[^ \t"'\'';]+/, "\\1=[SECRET_REDACTED]", line);
      }

      if (mask_mac_partial == 1) {
        rest=line; line="";
        while (match(rest, /([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}/)) {
          mac=substr(rest, RSTART, RLENGTH);
          line=line substr(rest,1,RSTART-1) mask_mac(mac);
          rest=substr(rest,RSTART+RLENGTH);
        }
        line=line rest;
      }

      rest=line; line="";
      while (match(rest, /([0-9]{1,3}\.){3}[0-9]{1,3}/)) {
        ip=substr(rest, RSTART, RLENGTH);
        rep=map_ipv4(ip);
        line=line substr(rest,1,RSTART-1) rep;
        rest=substr(rest,RSTART+RLENGTH);
      }
      line=line rest;

      if (mask_ipv6 == 1)
        gsub(/([0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}/, "[IPV6_REDACTED]", line);
      print line;
    }
  ' "$in" > "$out" 2>/dev/null || { rm -f "$map_append"; return 1; }
  [ -f "$map_append" ] && cat "$map_append" >> "$ANON_MAP_FILE"
  rm -f "$map_append"
  return 0
}

run_and_capture() {
  section="$1"; outfile="$2"; shift 2
  cmd="$*"
  tmp_out="${outfile}.stdout.tmp"
  tmp_err="${outfile}.stderr.tmp"
  ts="$(date -Iseconds 2>/dev/null || date)"

  if command -v timeout >/dev/null 2>&1; then
    timeout "${CMD_TIMEOUT_SEC}s" sh -c "$cmd" > "$tmp_out" 2> "$tmp_err"
    rc=$?
  else
    sh -c "$cmd" > "$tmp_out" 2> "$tmp_err"
    rc=$?
  fi

  {
    echo "===== BEGIN COMMAND ====="
    echo "CMD: $cmd"
    echo "SECTION: $section"
    echo "TIME: $ts"
    echo "RC: $rc"
    echo "----- STDOUT -----"
    cat "$tmp_out" 2>/dev/null
    echo "----- STDERR -----"
    cat "$tmp_err" 2>/dev/null
    echo "===== END COMMAND ====="
    echo
  } >> "$outfile"

  rm -f "$tmp_out" "$tmp_err"

  if [ "$rc" -eq 0 ]; then
    append_matrix "$outfile" "$cmd" "OK" "$rc"
    STATUS_OK=$((STATUS_OK + 1))
  else
    append_matrix "$outfile" "$cmd" "WARN" "$rc"
    record_warn "$section" "command failed rc=$rc: $cmd"
  fi
}

detect_pkg_manager() {
  if command -v apk >/dev/null 2>&1; then echo "apk"; return; fi
  if command -v opkg >/dev/null 2>&1; then echo "opkg"; return; fi
  echo "unknown"
}

parse_status_line() {
  line="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$line" in
    *not\ running*|*not\ r?nning*|*inactive*|*stopped*|*dead*) echo "off" ;;
    *running*|*r?nning*|*active*|*started*) echo "on" ;;
    *) echo "unknown" ;;
  esac
}

detect_clash_state_raw() {
  parser_service="unknown"
  parser_initd="unknown"
  proc_on=0
  port_on=0

  if command -v service >/dev/null 2>&1; then
    first_service="$(service "$CLASH_SERVICE_NAME" status 2>/dev/null | head -n1)"
    parser_service="$(parse_status_line "$first_service")"
  fi

  if [ -x "/etc/init.d/$CLASH_SERVICE_NAME" ]; then
    first_initd="$(/etc/init.d/"$CLASH_SERVICE_NAME" status 2>/dev/null | head -n1)"
    parser_initd="$(parse_status_line "$first_initd")"
  fi

  pidof clash >/dev/null 2>&1 && proc_on=1
  pidof mihomo >/dev/null 2>&1 && proc_on=1
  ps w 2>/dev/null | grep -Eq '[m]ihomo|[c]lash' && proc_on=1

  if command -v ss >/dev/null 2>&1; then
    ss -lntup 2>/dev/null | grep -Eq ':(7890|7891|7892|7893|7894)\b' && port_on=1
  fi

  if [ "$parser_service" = "on" ] || [ "$parser_initd" = "on" ]; then
    if [ "$proc_on" -eq 1 ] || [ "$port_on" -eq 1 ]; then
      echo "on"
    else
      echo "transition"
    fi
  elif [ "$parser_service" = "off" ] || [ "$parser_initd" = "off" ]; then
    if [ "$proc_on" -eq 0 ] && [ "$port_on" -eq 0 ]; then
      echo "off"
    else
      echo "transition"
    fi
  else
    if [ "$proc_on" -eq 1 ] || [ "$port_on" -eq 1 ]; then
      echo "on"
    else
      echo "unknown"
    fi
  fi
}

detect_clash_state() {
  raw_state="$(detect_clash_state_raw)"
  case "$raw_state" in
    on|off|unknown) echo "$raw_state" ;;
    transition) echo "unknown" ;;
    *)
      echo "unknown"
      ;;
  esac
}

set_clash_state() {
  target="$1"
  if ! command -v service >/dev/null 2>&1; then
    record_warn "service" "service command unavailable, cannot set clash $target"
    return 1
  fi

  if [ "$target" = "on" ]; then
    say "INFO" "Starting clash service"
    if command -v timeout >/dev/null 2>&1; then
      timeout "${SERVICE_CMD_TIMEOUT_SEC}s" service "$CLASH_SERVICE_NAME" start >/dev/null 2>&1 || true
    else
      service "$CLASH_SERVICE_NAME" start >/dev/null 2>&1 || true
    fi
  else
    say "INFO" "Stopping clash service"
    if command -v timeout >/dev/null 2>&1; then
      timeout "${SERVICE_CMD_TIMEOUT_SEC}s" service "$CLASH_SERVICE_NAME" stop >/dev/null 2>&1 || true
    else
      service "$CLASH_SERVICE_NAME" stop >/dev/null 2>&1 || true
    fi
  fi

  [ "$SERVICE_WAIT_LOG_INTERVAL_SEC" -le 0 ] && SERVICE_WAIT_LOG_INTERVAL_SEC=1
  i=0
  while [ "$i" -lt "$SERVICE_WAIT_MAX_SEC" ]; do
    now="$(detect_clash_state)"
    [ "$now" = "$target" ] && return 0
    if [ $((i % SERVICE_WAIT_LOG_INTERVAL_SEC)) -eq 0 ]; then
      say "INFO" "Waiting for clash=$target ... ${i}/${SERVICE_WAIT_MAX_SEC}s (current=$now)"
    fi
    sleep 1
    i=$((i + 1))
  done

  say "WARN" "Timeout after ${SERVICE_WAIT_MAX_SEC}s waiting clash=$target"
  record_warn "service" "failed to reach clash state=$target after timeout"
  return 1
}

check_missing_commands() {
  missing=""
  for c in ip nft fw4 uci ubus logread sed awk grep; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing="$missing $c"
      echo "missing_command=$c" >> "$RECO_LOG"
    fi
  done
  [ -n "$missing" ] && record_warn "preflight" "missing commands:$missing"
}

preflight_space_guard() {
  avail_kb="$(df -k "$OUT_BASE" 2>/dev/null | awk 'NR==2 {print $4}')"
  [ -n "$avail_kb" ] || avail_kb=0

  if [ "$avail_kb" -lt "$MIN_FREE_KB_HARD" ]; then
    record_error "preflight" "E_SPACE" "available=${avail_kb}KB < hard=${MIN_FREE_KB_HARD}KB"
    return 1
  fi
  if [ "$avail_kb" -lt "$MIN_FREE_KB_SOFT" ]; then
    DEGRADED=1
    record_warn "preflight" "low space, degraded mode enabled (${avail_kb}KB)"
  fi
  return 0
}

collect_static() {
  f="$STATIC_DIR/$(fname 01_system_baseline)"; init_log_file "$f" "system_baseline"
  run_and_capture "system" "$f" "uname -a"
  run_and_capture "system" "$f" "cat /etc/openwrt_release 2>/dev/null"
  run_and_capture "system" "$f" "cat /etc/os-release 2>/dev/null"
  run_and_capture "system" "$f" "ubus call system board 2>/dev/null"
  run_and_capture "system" "$f" "uptime"
  run_and_capture "system" "$f" "free -h"
  run_and_capture "system" "$f" "df -h"

  f="$STATIC_DIR/$(fname 02_packages_and_binaries)"; init_log_file "$f" "packages"
  pm="$(detect_pkg_manager)"
  run_and_capture "packages" "$f" "echo package_manager=$pm"
  [ "$pm" = "opkg" ] && run_and_capture "packages" "$f" "opkg list-installed"
  [ "$pm" = "apk" ] && run_and_capture "packages" "$f" "apk info -vv"
  run_and_capture "packages" "$f" "for b in nft ip iptables ip6tables fw4 tailscale mihomo clash logread ubus uci; do command -v \$b >/dev/null 2>&1 && echo \"\$b=ok\" || echo \"\$b=missing\"; done"

  f="$STATIC_DIR/$(fname 03_kernel_modules)"; init_log_file "$f" "kernel_modules"
  run_and_capture "modules" "$f" "lsmod"
  run_and_capture "modules" "$f" "modinfo nft_tproxy 2>/dev/null || true"
  run_and_capture "modules" "$f" "modinfo nf_tproxy_ipv4 2>/dev/null || true"
  run_and_capture "modules" "$f" "modinfo nf_tproxy_ipv6 2>/dev/null || true"
  run_and_capture "modules" "$f" "modinfo nft_socket 2>/dev/null || true"
}

collect_mode_runtime_dir() {
  mdir="$1"
  f="$mdir/$(fname 11_interfaces_runtime)"; init_log_file "$f" "interfaces_runtime"
  run_and_capture "interfaces" "$f" "ip -br link"
  run_and_capture "interfaces" "$f" "ip -br addr"
  run_and_capture "interfaces" "$f" "ip link show clash-tun 2>&1"

  f="$mdir/$(fname 12_routing_runtime)"; init_log_file "$f" "routing_runtime"
  run_and_capture "routing" "$f" "ip route show table all"
  run_and_capture "routing" "$f" "ip route show table 100"
  run_and_capture "routing" "$f" "ip route show table 101"
  run_and_capture "routing" "$f" "ip rule show"

  f="$mdir/$(fname 13_fw4_nft_runtime)"; init_log_file "$f" "fw4_nft_runtime"
  run_and_capture "firewall" "$f" "fw4 print"
  run_and_capture "firewall" "$f" "nft list ruleset"
  run_and_capture "firewall" "$f" "nft list ruleset | grep -Ei 'tproxy|mark|7894|clash|quic|443'"

  f="$mdir/$(fname 14_iptables_compat_audit)"; init_log_file "$f" "iptables_compat"
  run_and_capture "iptables" "$f" "iptables -t mangle -S 2>&1"
  run_and_capture "iptables" "$f" "iptables-save 2>&1"

  f="$mdir/$(fname 15_dns_runtime)"; init_log_file "$f" "dns_runtime"
  run_and_capture "dns" "$f" "cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null"
  run_and_capture "dns" "$f" "logread | tail -n $DNS_TAIL_LINES | grep -Ei 'dns|resolve|dnsmasq|servfail|timeout'"

  f="$mdir/$(fname 16_clash_tailscale_runtime)"; init_log_file "$f" "clash_tailscale_runtime"
  run_and_capture "runtime" "$f" "service \"$CLASH_SERVICE_NAME\" status 2>&1 || true"
  run_and_capture "runtime" "$f" "ps w | grep -Ei '[m]ihomo|[c]lash|[t]ailscale|[t]proxy' || true"
  run_and_capture "runtime" "$f" "ss -lntup | grep -E '7890|7891|7892|7893|7894' || true"

  f="$mdir/$(fname 17_sysctl_network_runtime)"; init_log_file "$f" "sysctl_runtime"
  run_and_capture "sysctl" "$f" "sysctl net.ipv4.ip_forward"
  run_and_capture "sysctl" "$f" "sysctl net.ipv4.conf.all.rp_filter"

  f="$mdir/$(fname 18_logs_filtered)"; init_log_file "$f" "logs_filtered"
  if [ "$DEGRADED" -eq 1 ]; then
    run_and_capture "logs" "$f" "logread | tail -n $LOG_TAIL_DEGRADED"
  else
    run_and_capture "logs" "$f" "logread | tail -n $LOG_TAIL_NORMAL"
  fi

  f="$mdir/$(fname 19_router_connectivity)"; init_log_file "$f" "connectivity"
  run_and_capture "connectivity" "$f" "ping -c 3 1.1.1.1"
  run_and_capture "connectivity" "$f" "nslookup openwrt.org 1.1.1.1 2>&1 || true"

  f="$mdir/$(fname 20_ipset_runtime)"; init_log_file "$f" "ipset_runtime"
  run_and_capture "ipset" "$f" "ipset list clash_fakeip_whitelist 2>&1 || true"
}

collect_ssclash_touchpoints() {
  ts="$(date -Iseconds 2>/dev/null || date)"
  {
    echo "### ssclash touchpoints"
    echo "TIME: $ts"
    echo "SSCLASH_DIR: $SSCLASH_DIR"
    echo "SSCLASH_FILE: $SSCLASH_FILE"
    echo
  } > "$TOUCH_LOG"

  files=""
  if [ -n "$SSCLASH_FILE" ]; then
    [ -f "$SSCLASH_FILE" ] && files="$SSCLASH_FILE" || record_warn "ssclash" "--ssclash-file not found: $SSCLASH_FILE"
  elif [ -d "$SSCLASH_DIR" ]; then
    files="$(find "$SSCLASH_DIR" -maxdepth 2 -type f \( -name 'clash-rules*' -o -name '*ssclash*' \) 2>/dev/null)"
  fi

  [ -z "$files" ] && { echo "NO_FILES_FOUND=1" >> "$TOUCH_LOG"; return 0; }
  for f in $files; do
    echo "===== FILE: $f =====" >> "$TOUCH_LOG"
    grep -nE 'uci |nft |ip rule|ip route|iptables|ip6tables|sysctl|service |/etc/init\.d/' "$f" >> "$TOUCH_LOG" 2>/dev/null || true
    grep -nE 'fwmark|0x0001|0x0002|0x0003|0xff00|table 100|table 101|clash-tun|7894|7890:7894|clash_fakeip_whitelist' "$f" >> "$TOUCH_LOG" 2>/dev/null || true
    echo >> "$TOUCH_LOG"
  done
}

make_anonymous_copy() {
  [ "$NO_ANON" -eq 1 ] && return 0
  tmp_list="${META_DIR}/.anon_filelist.$$"
  find "$RAW_ROOT" -type f > "$tmp_list" 2>/dev/null || true
  while read -r src; do
    [ -n "$src" ] || continue
    rel="${src#$RAW_ROOT/}"
    dst="$ANON_ROOT/$rel"
    mkdir -p "$(dirname "$dst")"
    mask_sensitive_data "$src" "$dst" || record_warn "anon" "failed to anonymize $src"
  done < "$tmp_list"
  rm -f "$tmp_list"
}

write_manifest() {
  {
    echo "script_version=$SCRIPT_VERSION"
    echo "mode=$MODE"
    echo "auto_mode=$AUTO_MODE"
    echo "session_id=$SESSION_ID"
    echo "hostname=$HOSTNAME_SHORT"
    echo "output_base=$OUT_BASE"
    echo "ssclash_dir=$SSCLASH_DIR"
    echo "ssclash_file=$SSCLASH_FILE"
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
    [ "$STATUS_FAIL" -gt 0 ] && echo "summary_result=FAIL" || {
      [ "$STATUS_WARN" -gt 0 ] && echo "summary_result=WARN" || echo "summary_result=OK"
    }
  } > "$SUMMARY_LOG"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --clash) REQUESTED_CLASH="${2:-}"; shift 2 ;;
      --auto) AUTO_MODE=1; shift ;;
      --out) OUT_BASE="${2:-}"; shift 2 ;;
      --ssclash-dir) SSCLASH_DIR="${2:-}"; shift 2 ;;
      --ssclash-file) SSCLASH_FILE="${2:-}"; shift 2 ;;
      --no-anon) NO_ANON=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done

  if [ -n "$REQUESTED_CLASH" ] && [ "$REQUESTED_CLASH" != "on" ] && [ "$REQUESTED_CLASH" != "off" ]; then
    echo "--clash must be on|off" >&2
    exit 2
  fi
}

prepare_paths() {
  mkdir -p "$OUT_BASE" || exit 2
  HOSTNAME_SHORT="$(detect_hostname)"
  SESSION_ID="$(date +%Y%m%d-%H%M%S)_${HOSTNAME_SHORT}"
  ROOT_DIR="$OUT_BASE/$SESSION_ID"
  RAW_ROOT="$ROOT_DIR/raw"
  ANON_ROOT="$ROOT_DIR/anon"
  META_DIR="$ROOT_DIR/meta"
  STATIC_DIR="$RAW_ROOT/00_static"
  mkdir -p "$STATIC_DIR" "$ANON_ROOT" "$META_DIR" || exit 2

  MANIFEST_LOG="$META_DIR/90_manifest.log"
  ERRORS_LOG="$META_DIR/91_errors.log"
  RECO_LOG="$META_DIR/92_recommendations.log"
  MATRIX_LOG="$META_DIR/93_collection_matrix.csv"
  TOUCH_LOG="$META_DIR/94_ssclash_touchpoints.log"
  EVENTS_LOG="$META_DIR/95_runtime_events.log"
  SUMMARY_LOG="$META_DIR/96_summary.log"
  RUN_LOG="$META_DIR/97_run_$(date +%Y%m%d-%H%M%S).log"
  ANON_MAP_FILE="$META_DIR/.anon_ipv4_map.tsv"

  touch "$MANIFEST_LOG" "$ERRORS_LOG" "$RECO_LOG" "$MATRIX_LOG" "$TOUCH_LOG" "$EVENTS_LOG" "$SUMMARY_LOG" "$RUN_LOG" "$ANON_MAP_FILE" || exit 2
}

collect_for_mode_label() {
  label="$1"; dir="$2"
  MODE="$label"
  mkdir -p "$dir"
  say "INFO" "Collecting diagnostics for $label -> $dir"
  collect_mode_runtime_dir "$dir"
}

manual_workflow() {
  detected="$(detect_clash_state)"
  if [ -n "$REQUESTED_CLASH" ]; then
    if [ "$REQUESTED_CLASH" = "on" ]; then MODE="Clash_ON"; mdir="$RAW_ROOT/11_mode_Clash_ON"; else MODE="Clash_OFF"; mdir="$RAW_ROOT/10_mode_Clash_OFF"; fi
    if [ "$detected" != "unknown" ] && [ "$detected" != "$REQUESTED_CLASH" ]; then
      record_warn "clash_state" "manual mode=$REQUESTED_CLASH but service state=$detected"
    fi
  else
    # default: auto-detect single snapshot
    if [ "$detected" = "on" ]; then MODE="Clash_ON"; mdir="$RAW_ROOT/11_mode_Clash_ON"; else MODE="Clash_OFF"; mdir="$RAW_ROOT/10_mode_Clash_OFF"; fi
    say "INFO" "No --clash parameter. Detected service state=$detected, selected mode=$MODE"
  fi
  collect_for_mode_label "$MODE" "$mdir"
}

auto_workflow() {
  initial="$(detect_clash_state)"
  initial_proc=0
  ps w 2>/dev/null | grep -Eq '[m]ihomo|[c]lash' && initial_proc=1
  say "INFO" "AUTO start; initial clash state=$initial"

  if [ "$initial" = "on" ]; then
    collect_for_mode_label "Clash_ON" "$RAW_ROOT/11_mode_Clash_ON"
    set_clash_state off
    now="$(detect_clash_state)"
    off_dir="$RAW_ROOT/10_mode_Clash_OFF"
    if [ "$now" != "off" ]; then
      record_warn "auto" "clash should be off but state=$now"
      off_dir="${off_dir}_untrusted"
    fi
    collect_for_mode_label "Clash_OFF" "$off_dir"

    now="$(detect_clash_state)"
    on_post_dir="$RAW_ROOT/12_mode_Clash_ON_post"
    if [ "$now" != "off" ]; then
      record_warn "auto" "clash restarted unexpectedly before ON-post capture"
      on_post_dir="${on_post_dir}_untrusted"
    fi
    set_clash_state on
    now="$(detect_clash_state)"
    if [ "$now" != "on" ]; then
      record_warn "auto" "clash failed to start for ON-post capture"
      on_post_dir="${on_post_dir}_untrusted"
    fi
    collect_for_mode_label "Clash_ON_POST" "$on_post_dir"

    set_clash_state on >/dev/null 2>&1 || true
  else
    # treat unknown as off-oriented path with warnings
    [ "$initial" = "unknown" ] && record_warn "auto" "initial clash state unknown; proceeding with off->on->off sequence"
    set_clash_state off
    now="$(detect_clash_state)"
    off_dir="$RAW_ROOT/10_mode_Clash_OFF"
    if [ "$now" != "off" ]; then
      record_warn "auto" "failed to stabilize OFF state before OFF capture"
      off_dir="${off_dir}_untrusted"
    fi
    collect_for_mode_label "Clash_OFF" "$off_dir"

    set_clash_state on
    now="$(detect_clash_state)"
    on_dir="$RAW_ROOT/11_mode_Clash_ON"
    if [ "$now" != "on" ]; then
      record_warn "auto" "clash failed to start before ON capture"
      on_dir="${on_dir}_untrusted"
    fi
    collect_for_mode_label "Clash_ON" "$on_dir"

    now="$(detect_clash_state)"
    [ "$now" != "on" ] && record_warn "auto" "clash unexpectedly not running after ON capture"
    set_clash_state off
  fi

  # restore to initial known state
  if [ "$initial" = "on" ]; then
    set_clash_state on || record_warn "auto" "failed to restore initial state: on"
  elif [ "$initial" = "off" ]; then
    set_clash_state off || record_warn "auto" "failed to restore initial state: off"
  else
    # unknown status format: fallback to initial process presence heuristic
    if [ "$initial_proc" -eq 1 ]; then
      set_clash_state on || record_warn "auto" "failed to restore guessed initial state: on (from process heuristic)"
    else
      set_clash_state off || record_warn "auto" "failed to restore guessed initial state: off (from process heuristic)"
    fi
  fi
}

main() {
  parse_args "$@"
  prepare_paths
  log_event "session started"
  say "INFO" "Session directory: $ROOT_DIR"

  preflight_space_guard || { write_manifest; write_summary; exit 2; }
  check_missing_commands
  collect_static
  collect_ssclash_touchpoints

  if [ "$AUTO_MODE" -eq 1 ]; then
    auto_workflow
  else
    manual_workflow
  fi

  make_anonymous_copy
  write_manifest
  write_summary
  log_event "session finished"
  say "INFO" "Completed. Summary: ok=$STATUS_OK warn=$STATUS_WARN fail=$STATUS_FAIL"

  if [ "$STATUS_FAIL" -gt 0 ]; then exit 2; fi
  if [ "$STATUS_WARN" -gt 0 ]; then exit 1; fi
  exit 0
}

main "$@"
