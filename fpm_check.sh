#!/usr/bin/env bash
# =============================================================================
# fpm_check.sh — READ-ONLY PHP-FPM / worker audit for Cloudways servers
#
# Shows per-app and server-wide: live workers, RSS, configured pm.* ceilings,
# request_terminate_timeout, fpm-pool.conf overrides, cgroup MemoryMax, and
# recent max_children / OOM signals. Makes NO configuration changes.
#
# Usage (on the server as root or master with read access):
#   curl -fsSL https://raw.githubusercontent.com/sultan8898/homeabc/cursor/fpm-outage-runbook-110523-e763/fpm_check.sh | bash
#   curl -fsSL .../fpm_check.sh | bash -s -- jwhjhhbyqd
#   curl -fsSL .../fpm_check.sh | bash -s -- --brief
#
# Options:
#   --brief     shorter per-app block
#   APP         one sys_user only (default: all apps)
# =============================================================================

set -uo pipefail

BRIEF=0
FILTER_APP=""
for arg in "$@"; do
  case "$arg" in
    --brief|-b) BRIEF=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" 2>/dev/null || true
      echo "Usage: bash fpm_check.sh [--brief] [sys_user]"
      exit 0
      ;;
    *) FILTER_APP="$arg" ;;
  esac
done

hr() { printf '%s\n' "=========================================================="; }
section() { echo; hr; echo " $*"; hr; }

list_apps() {
  if [[ -d /home/master/applications ]]; then
    ls -1 /home/master/applications 2>/dev/null | grep -E '^[a-z0-9]+$' || true
  elif [[ -d /home ]]; then
    # fallback: server-id home layout
    local sid
    sid="$(ls -1d /home/*.cloudwaysapps.com 2>/dev/null | head -1)"
    [[ -n "$sid" ]] || return 0
    ls -1 "$sid" 2>/dev/null | grep -E '^[a-z0-9]+$' || true
  fi
}

server_home_for() {
  local u="$1" d
  if [[ -d "/home/master/applications/$u" ]]; then
    echo "/home/master/applications/$u"
    return
  fi
  for d in /home/*.cloudwaysapps.com; do
    [[ -d "$d/$u" ]] && { echo "$d/$u"; return; }
  done
}

php_ver_for() {
  local u="$1" ver="" home
  home="$(server_home_for "$u")"
  if [[ -f "$home/.php_version" ]]; then
    ver="$(tr -d '[:space:]' < "$home/.php_version")"
  fi
  if [[ -z "$ver" && -f /etc/ansible/facts.d/applications.fact ]]; then
    ver="$(awk -F= -v u="$u" '
      $0 ~ /^\[app_php_version\]/ {insec=1; next}
      /^\[/ {insec=0}
      insec && $1==u {gsub(/\r/,"",$2); print $2; exit}
    ' /etc/ansible/facts.d/applications.fact)"
  fi
  if [[ -z "$ver" ]]; then
    local f
    f="$(ls /etc/php/*/fpm/pool.d/"${u}"-*.conf 2>/dev/null | head -1)"
    [[ -n "$f" ]] && ver="$(echo "$f" | sed -n 's|.*/php/\([0-9.]*\)/fpm/.*|\1|p')"
  fi
  echo "$ver"
}

domain_for() {
  local home="$1"
  awk 'NR==1{print substr($NF,1,length($NF)-1)}' "$home/conf/server.nginx" 2>/dev/null || echo "?"
}

pool_file_for() {
  local u="$1" ver="$2" short f
  short="$(echo "$ver" | tr -d '.')"
  f="/etc/php/${ver}/fpm/pool.d/${u}-${short}.conf"
  [[ -f "$f" ]] && { echo "$f"; return; }
  ls /etc/php/*/fpm/pool.d/"${u}"-*.conf 2>/dev/null | head -1
}

# Effective directive: last matching assignment across files (later wins)
eff_val() {
  local key="$1"; shift
  local f last=""
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    # last non-comment match
    local v
    v="$(grep -E "^${key}[[:space:]]*=" "$f" 2>/dev/null | tail -1 | sed -E "s/^${key}[[:space:]]*=[[:space:]]*//")"
    [[ -n "$v" ]] && last="$v"
  done
  echo "${last:--}"
}

live_pool_stats() {
  # prints: workers rss_mib for pool name arg (e.g. jwhjhhbyqd-84)
  local pool="$1"
  ps -eo rss=,args= 2>/dev/null | awk -v p="$pool" '
    $0 ~ ("php-fpm: pool " p "$") || $0 ~ ("php-fpm: pool " p " ") {
      n++; r+=$1
    }
    END { printf "%d %d", n+0, int(r/1024+0.5) }
  '
}

# -----------------------------------------------------------------------------
section "PHP-FPM READ-ONLY AUDIT  $(date -u '+%Y-%m-%d %H:%M:%S UTC')  host=$(hostname -f 2>/dev/null || hostname)"
echo "Mode: READ-ONLY (no config changes)"
echo "Filter: ${FILTER_APP:-all apps}"

section "0. Host snapshot"
uptime
free -h 2>/dev/null || free -m
if [[ -r /proc/pressure/memory ]]; then
  echo "-- Memory PSI --"
  cat /proc/pressure/memory
fi
echo "-- Swap --"
swapon --show 2>/dev/null || true

section "1. PHP-FPM services + cgroup ceilings"
for ver in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
  svc="php${ver}-fpm"
  systemctl list-unit-files "${svc}.service" &>/dev/null || continue
  state="$(systemctl is-active "$svc" 2>/dev/null || echo n/a)"
  mem="$(systemctl show "$svc" -p MemoryMax -p MemoryHigh -p MemoryCurrent --value 2>/dev/null | paste -sd' ' -)"
  printf "%-14s active=%-8s MemoryMax/High/Current(bytes)= %s\n" "$svc" "$state" "${mem:-n/a}"
done

section "2. Global extras (cw_customization.conf)"
GLOBAL="/etc/php.confs/fpm/extras/cw_customization.conf"
if [[ -f "$GLOBAL" ]]; then
  grep -E '^(pm |pm\.|request_terminate|request_slowlog)' "$GLOBAL" 2>/dev/null || cat "$GLOBAL"
else
  echo "(missing $GLOBAL)"
fi

section "3. Live workers by pool (RSS)"
printf "%-18s %8s %10s\n" "POOL" "WORKERS" "RSS_MiB"
ps -eo rss=,args= 2>/dev/null | awk '
  /php-fpm: pool / {
    pool=$NF
    n[pool]++; r[pool]+=$1
  }
  END {
    for (p in n) printf "%-18s %8d %10d\n", p, n[p], int(r[p]/1024+0.5)
  }
' | sort -k3 -nr

TOTAL_WORKERS="$(ps -eo args= 2>/dev/null | grep -c 'php-fpm: pool ' || true)"
TOTAL_RSS="$(ps -eo rss=,args= 2>/dev/null | awk '/php-fpm: pool /{s+=$1} END{print int(s/1024+0.5)}')"
echo "TOTAL live pool workers=${TOTAL_WORKERS:-0}  combined_RSS_MiB=${TOTAL_RSS:-0}"

section "4. Per-application detail"
SUM_MAX=0
APPS_N=0

while IFS= read -r app; do
  [[ -z "$app" ]] && continue
  [[ -n "$FILTER_APP" && "$app" != "$FILTER_APP" ]] && continue
  home="$(server_home_for "$app")"
  [[ -n "$home" && -d "$home" ]] || continue
  ver="$(php_ver_for "$app")"
  pool_file="$(pool_file_for "$app" "${ver:-}")"
  pool_name=""
  [[ -n "$pool_file" ]] && pool_name="$(basename "$pool_file" .conf)"
  fpm_pool="${home}/conf/fpm-pool.conf"
  domain="$(domain_for "$home")"

  # Config sources (later wins for display via eff_val)
  maxc="$(eff_val 'pm.max_children' "$GLOBAL" "$pool_file" "$fpm_pool")"
  pm="$(eff_val 'pm' "$GLOBAL" "$pool_file" "$fpm_pool")"
  maxreq="$(eff_val 'pm.max_requests' "$GLOBAL" "$pool_file" "$fpm_pool")"
  idle="$(eff_val 'pm.process_idle_timeout' "$GLOBAL" "$pool_file" "$fpm_pool")"
  rtt="$(eff_val 'request_terminate_timeout' "$GLOBAL" "$pool_file" "$fpm_pool")"
  slow="$(eff_val 'request_slowlog_timeout' "$GLOBAL" "$pool_file" "$fpm_pool")"
  memlim="$(eff_val 'php_admin_value\[memory_limit\]' "$fpm_pool" "$pool_file")"
  # memory_limit may use php_admin_value[memory_limit]= form without spaces
  if [[ "$memlim" == "-" && -f "$fpm_pool" ]]; then
    memlim="$(grep -E '^php_admin_value\[memory_limit\]' "$fpm_pool" 2>/dev/null | tail -1 | sed -E 's/^[^=]+=//')"
    memlim="${memlim:--}"
  fi

  live_w=0; live_rss=0
  if [[ -n "$pool_name" ]]; then
    read -r live_w live_rss <<<"$(live_pool_stats "$pool_name")"
  fi

  util="n/a"
  if [[ "$maxc" =~ ^[0-9]+$ && "$maxc" -gt 0 ]]; then
    util="$(awk -v w="$live_w" -v m="$maxc" 'BEGIN{printf "%.0f%%", (w/m)*100}')"
    SUM_MAX=$((SUM_MAX + maxc))
  fi
  APPS_N=$((APPS_N + 1))

  echo
  echo "---------- $app  |  $domain  |  PHP ${ver:-?}  |  pool ${pool_name:-?} ----------"
  printf "  live_workers=%s  live_RSS_MiB=%s  pm.max_children=%s  utilization=%s\n" \
    "$live_w" "$live_rss" "$maxc" "$util"
  printf "  pm=%s  pm.max_requests=%s  process_idle_timeout=%s\n" "$pm" "$maxreq" "$idle"
  printf "  request_terminate_timeout=%s  request_slowlog_timeout=%s  memory_limit=%s\n" \
    "$rtt" "$slow" "$memlim"

  if [[ "$BRIEF" -eq 0 ]]; then
    echo "  sources:"
    echo "    global:   $GLOBAL"
    echo "    pool.d:   ${pool_file:-none}"
    echo "    app conf: $fpm_pool $([[ -f $fpm_pool ]] && echo '[present]' || echo '[missing]')"
    if [[ -f "$fpm_pool" ]]; then
      echo "    fpm-pool.conf pm.*/terminate lines:"
      grep -E '^(pm |pm\.|request_terminate)' "$fpm_pool" 2>/dev/null | sed 's/^/      /' || echo "      (none)"
    fi
    # recent max_children warnings for this pool
    if [[ -n "$pool_name" ]]; then
      warn_n="$(grep -h "pool ${pool_name}" /var/log/php*-fpm.log /var/log/php/*fpm*.log 2>/dev/null \
        | grep -c 'pm.max_children' || true)"
      echo "  max_children warnings in fpm logs (grep hit count): ${warn_n:-0}"
    fi
    # recent 499 / upstream in app error log
    if [[ -d "$home/logs" ]]; then
      n499="$(tail -n 2000 "$home/logs/nginx-app.status.log" 2>/dev/null | awk '$9==499' | wc -l | tr -d ' ')"
      up_err="$(tail -n 500 "$home/logs"/*error.log 2>/dev/null \
        | grep -ciE 'upstream timed out|connect\(\) failed|no live upstreams' || true)"
      echo "  nginx last2k 499s=${n499:-0}  recent upstream/timeout errors≈${up_err:-0}"
    fi
  fi
done < <(list_apps)

section "5. Aggregate summary"
echo "apps_scanned=${APPS_N}"
echo "sum_configured_pm.max_children=${SUM_MAX}  (theoretical max if every pool saturated)"
echo "live_pool_workers=${TOTAL_WORKERS:-0}  live_combined_RSS_MiB=${TOTAL_RSS:-0}"
echo "global_default_max_children=$(eff_val 'pm.max_children' "$GLOBAL")"
echo "global_request_terminate_timeout=$(eff_val 'request_terminate_timeout' "$GLOBAL")"

section "6. Recent OOM / FPM saturation signals"
dmesg -T 2>/dev/null | grep -iE 'oom-kill|Out of memory|killed process' | tail -n 15 || echo "(no dmesg oom lines)"
echo "-- php-fpm max_children warnings (last 15 across logs) --"
grep -h 'pm.max_children' /var/log/php*-fpm.log /var/log/php/*fpm*.log 2>/dev/null | tail -n 15 || echo "(none found)"

section "7. Done"
echo "READ-ONLY complete. No files were modified."
echo "Tip: re-run with --brief for a compact table-like scan; pass a sys_user to focus one app."
