#!/usr/bin/env bash
# =============================================================================
# Server 110523 (Michael Scott / 178.62.1.140) — PHP-FPM saturation runbook
#
# Run as root on the server. Sections are labeled; copy/paste a section or:
#   bash fpm_outage_110523.sh discover
#   bash fpm_outage_110523.sh recover
#   bash fpm_outage_110523.sh block-abuse
#   bash fpm_outage_110523.sh apply-global
#   bash fpm_outage_110523.sh apply-pools
#   bash fpm_outage_110523.sh nginx-probes
#   bash fpm_outage_110523.sh verify
#   bash fpm_outage_110523.sh cf-bypass
#
# Memory budget (8 GiB / 4 cores) — customer-safe targets (~20–30% below default 40):
#   Observed Marmais: 40 workers ≈ 6.4 GiB RSS (~160 MiB/worker incl. shared)
#   Probe WordPress 404s: ~234 MiB/request
#   Aggressive cuts (e.g. 40→3/6) WILL cause 502/503 under legitimate traffic —
#   do NOT ship those. Prefer modest ceiling + IP blocks + nginx probe reject.
#
# Suggested ceilings (~25% below current default of 40):
#   Global / smaller apps:           30   (was 40, −25%)
#   Marmais (jwhjhhbyqd):            28   (was 40, −30%)
#   Hope City / Building Blocks:     28
#   Other high-traffic:              30
#   Dev / low-traffic:               28
#
# Pair with: AbuseIPDB blocks, nginx vuln-probe 403, request_terminate_timeout,
# and optional systemd MemoryMax as a backstop (not a substitute for blocking).
#
# NOTE: Cloudways Platform "PHP Settings" API rejects pm.* (HTTP 422 reserved).
# Use PHP-FPM Settings (MCP app_fpm_settings_update) OR root edits below.
# Ansible/platform reconfigs can overwrite pool files — re-check after stack ops.
# =============================================================================

set -euo pipefail

MARMAIS_SYSUSER="${MARMAIS_SYSUSER:-jwhjhhbyqd}"
MARMAIS_PHP_VER="${MARMAIS_PHP_VER:-8.4}"
GLOBAL_FPM_EXTRAS="/etc/php.confs/fpm/extras/cw_customization.conf"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="/root/fpm_outage_backup_${STAMP}"

# Customer-safe defaults: ~20–30% below stock 40 (NOT aggressive 3/6)
DEFAULT_MAX_CHILDREN="${DEFAULT_MAX_CHILDREN:-30}"
MARMAIS_MAX_CHILDREN="${MARMAIS_MAX_CHILDREN:-28}"
HIGH_TRAFFIC_MAX_CHILDREN="${HIGH_TRAFFIC_MAX_CHILDREN:-28}"
DEV_MAX_CHILDREN="${DEV_MAX_CHILDREN:-28}"
REQUEST_TERMINATE_TIMEOUT="${REQUEST_TERMINATE_TIMEOUT:-60s}"
REQUEST_SLOWLOG_TIMEOUT="${REQUEST_SLOWLOG_TIMEOUT:-10s}"

# Confirmed abusive scanners (AbuseIPDB 98–100 + customer-corroborated)
# 34.34.44.74: customer identified as major Marmais outage contributor (127 hits in sample)
ABUSE_IPS=(
  216.244.66.227
  35.240.5.212
  34.14.32.225
  34.34.44.74
  207.175.102.161
  34.77.244.113
  34.78.28.241
  34.14.118.80
  193.37.32.40
  194.5.82.9
  194.5.82.43
  129.146.50.223
  32.195.61.205
)

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run as root"; }

list_sysusers() {
  ls -1 /home/master/applications 2>/dev/null | grep -E '^[a-z0-9]+$' || true
}

php_ver_for() {
  local u="$1"
  # Prefer ansible facts, fall back to pool path / running process
  if [[ -f /etc/ansible/facts.d/applications.fact ]]; then
    awk -F= -v u="$u" '
      $0 ~ /^\[app_php_version\]/ {insec=1; next}
      /^\[/ {insec=0}
      insec && $1==u {gsub(/\r/,"",$2); print $2; exit}
    ' /etc/ansible/facts.d/applications.fact
  fi
}

pool_conf_for() {
  local u="$1" ver
  ver="$(php_ver_for "$u")"
  [[ -n "$ver" ]] || return 1
  local c="/etc/php/${ver}/fpm/pool.d/${u}.conf"
  [[ -f "$c" ]] && echo "$c" && return 0
  # Cloudways sometimes keeps a conf under the app
  for c in \
    "/home/master/applications/${u}/conf/fpm-pool.conf" \
    "/home/master/applications/${u}/conf/php-fpm.conf"; do
    [[ -f "$c" ]] && echo "$c" && return 0
  done
  return 1
}

domain_for() {
  local u="$1"
  awk 'NR==1{print substr($NF,1,length($NF)-1)}' \
    "/home/master/applications/${u}/conf/server.nginx" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
cmd_discover() {
  need_root
  echo "=== DISCOVER $(date -u) ==="
  uptime
  free -h
  echo
  echo "-- Worker RSS by pool (top) --"
  ps -eo rss,args | awk '/php-fpm: pool /{a[$NF]+=$1;n[$NF]++}
    END{for(p in a) printf "%-16s %3d workers  %6.0f MiB RSS\n", p, n[p], a[p]/1024}
  ' | sort -k4 -nr

  echo
  echo "-- Current pm.max_children / terminate timeouts --"
  grep -rH --include='*.conf' -E '^(pm\.max_children|request_terminate_timeout|pm =)' \
    /etc/php/*/fpm/pool.d/ /etc/php.confs/fpm/extras/ 2>/dev/null | sort || true

  echo
  echo "-- App inventory (sys_user → PHP → domain) --"
  printf "%-14s %-5s %-6s %s\n" "SYSUSER" "PHP" "STATE" "DOMAIN"
  local u ver st
  for u in $(list_sysusers); do
    ver="$(php_ver_for "$u")"; ver="${ver:-?}"
    st="enable"
    if [[ -f /etc/ansible/facts.d/applications.fact ]]; then
      if grep -qE "^state_${u}=disable" /etc/ansible/facts.d/applications.fact 2>/dev/null; then
        st="disable"
      fi
    fi
    printf "%-14s %-5s %-6s %s\n" "$u" "$ver" "$st" "$(domain_for "$u")"
  done

  echo
  echo "-- Theoretical max workers (sum of pm.max_children) --"
  awk -F= '/^pm\.max_children/ {gsub(/ /,"",$2); s+=$2; c++}
    END{printf "pools=%d  sum_max_children=%d\n", c+0, s+0}' \
    /etc/php/*/fpm/pool.d/*.conf 2>/dev/null || true

  echo
  echo "-- OOM killer (dmesg + syslog) --"
  dmesg -T 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -n 30 || true
  grep -iE 'oom-kill|out of memory|killed process' /var/log/syslog 2>/dev/null | tail -n 20 || true
}

# -----------------------------------------------------------------------------
# Immediate recovery: isolate Marmais, restart FPM, health-check stack
cmd_recover() {
  need_root
  mkdir -p "$BACKUP_DIR"
  echo "=== RECOVER $(date -u) backup=$BACKUP_DIR ==="

  local pool
  pool="$(pool_conf_for "$MARMAIS_SYSUSER" || true)"
  [[ -n "$pool" ]] || die "cannot locate pool conf for $MARMAIS_SYSUSER"

  cp -a "$pool" "$BACKUP_DIR/"
  echo "Backing up $pool"

  # Temporarily clamp Marmais so it cannot keep saturating the box
  if grep -qE '^pm\.max_children' "$pool"; then
    sed -i -E "s/^pm\.max_children\s*=.*/pm.max_children = 2/" "$pool"
  else
    printf '\npm.max_children = 2\n' >> "$pool"
  fi
  # Prefer ondemand during incident to shed idle workers
  if grep -qE '^pm\s*=' "$pool"; then
    sed -i -E 's/^pm\s*=.*/pm = ondemand/' "$pool"
  else
    printf '\npm = ondemand\n' >> "$pool"
  fi

  echo "-- Marmais pool after clamp --"
  grep -E '^(pm|pm\.|request_terminate)' "$pool" || true

  echo "-- Restarting PHP-FPM (all versions present) --"
  local svc
  for svc in php7.4-fpm php8.1-fpm php8.2-fpm php8.3-fpm php8.4-fpm; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
      systemctl restart "$svc" && echo "restarted $svc" || echo "WARN: failed $svc"
    fi
  done

  # Force-kill any leftover Marmais workers if still thrashing
  pkill -f "php-fpm: pool ${MARMAIS_SYSUSER}" 2>/dev/null || true
  sleep 2

  echo "-- Health checks --"
  for svc in nginx apache2 mariadb mysql redis-server \
             php7.4-fpm php8.4-fpm; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
      systemctl is-active --quiet "$svc" \
        && echo "OK  $svc" \
        || echo "BAD $svc ($(systemctl is-active "$svc" 2>/dev/null || true))"
    fi
  done

  echo
  free -h
  uptime
  ps -eo rss,args | awk -v p="$MARMAIS_SYSUSER" '
    $0 ~ "php-fpm: pool "p {n++; r+=$1}
    END{printf "Marmais workers now: %d  RSS=%.0f MiB\n", n+0, r/1024}
  '

  echo
  echo "-- MariaDB OOM history --"
  dmesg -T 2>/dev/null | grep -iE 'oom-kill|killed process.*(mariad|mysqld)' | tail -n 20 || true
  grep -iE 'oom-kill|killed process.*(mariad|mysqld)' /var/log/syslog 2>/dev/null | tail -n 20 || true
}

# -----------------------------------------------------------------------------
# Permanent: lower server-wide default in cw_customization.conf
cmd_apply_global() {
  need_root
  mkdir -p "$BACKUP_DIR"
  [[ -f "$GLOBAL_FPM_EXTRAS" ]] || die "missing $GLOBAL_FPM_EXTRAS"
  cp -a "$GLOBAL_FPM_EXTRAS" "$BACKUP_DIR/cw_customization.conf.bak"

  # Effective global defaults
  cat > "$GLOBAL_FPM_EXTRAS" <<EOF
; Cloudways extras — tightened for 8 GiB / 4 vCPU host (server 110523)
; Applied: ${STAMP}
pm = dynamic
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_spare_servers = 1
pm.max_children = ${DEFAULT_MAX_CHILDREN}
pm.max_requests = 500
pm.process_idle_timeout = 10s
request_terminate_timeout = ${REQUEST_TERMINATE_TIMEOUT}
request_slowlog_timeout = ${REQUEST_SLOWLOG_TIMEOUT}
php_admin_flag[newrelic.framework.wordpress.hooks] = false
php_flag[mail.add_x_header] = On
env[WP_REDIS_DISABLED] = "0"
EOF

  echo "Wrote $GLOBAL_FPM_EXTRAS :"
  cat "$GLOBAL_FPM_EXTRAS"
  echo
  echo "Effective global values:"
  echo "  pm.max_children              = ${DEFAULT_MAX_CHILDREN}"
  echo "  request_terminate_timeout    = ${REQUEST_TERMINATE_TIMEOUT}"
  echo "  request_slowlog_timeout      = ${REQUEST_SLOWLOG_TIMEOUT}"
  echo "  pm.process_idle_timeout      = 10s"
  echo "  pm.max_requests              = 500"
}

# -----------------------------------------------------------------------------
# Permanent: per-pool overrides (alphabetical z- override files so they win)
# Set HIGH_TRAFFIC_USERS / DEV_USERS env vars (space-separated sys_users).
cmd_apply_pools() {
  need_root
  mkdir -p "$BACKUP_DIR"

  # Known: Marmais. Export others after discover, e.g.:
  #   HIGH_TRAFFIC_USERS="abcd1234 efgh5678" DEV_USERS="devuser1" bash ... apply-pools
  local high="${HIGH_TRAFFIC_USERS:-}"
  local mid="${MID_TRAFFIC_USERS:-}"
  local dev="${DEV_USERS:-}"
  local u ver pooldir override children

  apply_one() {
    local user="$1" maxc="$2"
    ver="$(php_ver_for "$user")"
    [[ -n "$ver" ]] || { echo "SKIP $user (no php version)"; return; }
    pooldir="/etc/php/${ver}/fpm/pool.d"
    [[ -d "$pooldir" ]] || { echo "SKIP $user (no $pooldir)"; return; }
    # Backup original pool
    [[ -f "${pooldir}/${user}.conf" ]] && cp -a "${pooldir}/${user}.conf" "$BACKUP_DIR/"
    override="${pooldir}/z-${user}-limits.conf"
    cat > "$override" <<EOF
; Per-app FPM ceiling override for [${user}] — server 110523 ${STAMP}
[${user}]
pm = dynamic
pm.max_children = ${maxc}
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_spare_servers = 1
pm.max_requests = 500
pm.process_idle_timeout = 10s
request_terminate_timeout = ${REQUEST_TERMINATE_TIMEOUT}
request_slowlog_timeout = ${REQUEST_SLOWLOG_TIMEOUT}
EOF
    echo "OK  $user php${ver}  pm.max_children=${maxc}  -> $override"
  }

  apply_one "$MARMAIS_SYSUSER" "$MARMAIS_MAX_CHILDREN"

  for u in $high; do
    [[ "$u" == "$MARMAIS_SYSUSER" ]] && continue
    apply_one "$u" "$HIGH_TRAFFIC_MAX_CHILDREN"
  done
  for u in $mid; do
    apply_one "$u" "$DEFAULT_MAX_CHILDREN"
  done
  for u in $dev; do
    apply_one "$u" "$DEV_MAX_CHILDREN"
  done

  echo
  echo "-- Aggregate check (override files + defaults) --"
  echo "After reload, run: bash $0 verify"
  echo "Ceilings are ~20–30% below 40. Pair with: bash $0 block-abuse"

  local svc bin
  for svc in php7.4-fpm php8.4-fpm; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
      bin="/usr/sbin/${svc}"
      if [[ -x "$bin" ]]; then
        "$bin" -t || die "configtest failed for $svc — aborting reload"
      else
        echo "WARN: $bin missing; proceeding with reload"
      fi
      systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc"
      echo "reloaded $svc"
    fi
  done
}

# -----------------------------------------------------------------------------
# Soft aggregate ceiling: systemd MemoryMax on php*-fpm units.
# Optional backstop only — with max_children≈28–30 this is a safety net, not
# the primary control. Leave headroom for MariaDB (~1.5–2G) + Redis (~250–800M).
cmd_apply_cgroup() {
  need_root
  local ver unit drop max high
  for ver in 7.4 8.4; do
    unit="php${ver}-fpm"
    systemctl list-unit-files "${unit}.service" &>/dev/null || continue
    drop="/etc/systemd/system/${unit}.service.d"
    mkdir -p "$drop"
    if [[ "$ver" == "8.4" ]]; then
      max="4500M"; high="4000M"
    else
      max="1800M"; high="1600M"
    fi
    cat > "${drop}/memory-ceiling.conf" <<EOF
[Service]
# Soft backstop so FPM cannot eat the whole host under scanner storms.
MemoryAccounting=yes
MemoryMax=${max}
MemoryHigh=${high}
EOF
    echo "Wrote ${drop}/memory-ceiling.conf (MemoryMax=${max} MemoryHigh=${high})"
  done
  systemctl daemon-reload
  for ver in 7.4 8.4; do
    systemctl try-restart "php${ver}-fpm" 2>/dev/null || true
  done
  echo "FPM cgroup backstop ≈ 6300M across PHP 7.4+8.4 (still leaves ~1.5G+ for DB/OS)."
}

# -----------------------------------------------------------------------------
# Block confirmed abusive IPs.
# Cloudways Flexible often has NO csf — use nginx geo + iptables/ipset,
# and Imunify360 blacklist if imunify360-agent is present.
cmd_block_abuse() {
  need_root
  mkdir -p "$BACKUP_DIR"
  local ip ngmap="/etc/nginx/conf.d/01-abuse-ip-deny.conf"

  echo "=== BLOCK ABUSE IPS $(date -u) ==="

  if command -v csf >/dev/null 2>&1; then
    for ip in "${ABUSE_IPS[@]}"; do
      csf -d "$ip" "110523 AbuseIPDB/scanner $(date +%F)" || true
      echo "CSF deny $ip"
    done
  else
    echo "CSF not installed — using nginx geo + iptables/ipset (+ Imunify if available)"
  fi

  # Imunify360 permanent blacklist (when present)
  if command -v imunify360-agent >/dev/null 2>&1; then
    for ip in "${ABUSE_IPS[@]}"; do
      imunify360-agent blacklist ip add "$ip" --comment "110523 abusive scanner" 2>/dev/null \
        || imunify360-agent ip-list local add --by-ip "$ip" 2>/dev/null \
        || echo "WARN: imunify add failed for $ip (try UI / check subcommand)"
    done
  fi

  # Kernel-level drop via ipset + iptables (persistent until reboot unless saved)
  if command -v ipset >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
    ipset create cw_abuse hash:ip -exist
    for ip in "${ABUSE_IPS[@]}"; do
      ipset add cw_abuse "$ip" -exist
      echo "ipset add $ip"
    done
    iptables -C INPUT -m set --match-set cw_abuse src -j DROP 2>/dev/null \
      || iptables -I INPUT -m set --match-set cw_abuse src -j DROP
    iptables -C INPUT -p tcp -m multiport --dports 80,443 -m set --match-set cw_abuse src -j DROP 2>/dev/null \
      || true
    echo "iptables DROP active for set cw_abuse"
  elif command -v iptables >/dev/null 2>&1; then
    for ip in "${ABUSE_IPS[@]}"; do
      iptables -C INPUT -s "$ip" -j DROP 2>/dev/null || iptables -I INPUT -s "$ip" -j DROP
      echo "iptables DROP $ip"
    done
  fi

  {
    echo "# Abuse scanners observed on 110523 — ${STAMP}"
    echo "geo \$cw_abuse_ip {"
    echo "    default 0;"
    for ip in "${ABUSE_IPS[@]}"; do
      echo "    ${ip} 1;"
    done
    echo "}"
  } > "$ngmap"

  local u custom
  for u in $(list_sysusers); do
    custom="/home/master/applications/${u}/conf/nginx.custom"
    mkdir -p "$(dirname "$custom")"
    [[ -f "$custom" ]] && cp -a "$custom" "$BACKUP_DIR/nginx.custom.${u}.pre-abuse" 2>/dev/null || true
    if [[ -f "$custom" ]] && grep -q 'cw_abuse_ip' "$custom" 2>/dev/null; then
      echo "OK  $u already has cw_abuse_ip rule"
      continue
    fi
    cat >> "$custom" <<'EOF'

# Deny known abusive scanners (server 110523)
if ($cw_abuse_ip) { return 403; }
EOF
    chown master:master "$custom" 2>/dev/null || true
    echo "OK  abuse deny -> $custom"
  done

  nginx -t && systemctl reload nginx
  echo
  echo "Blocked / mapped IPs:"
  printf '  %s\n' "${ABUSE_IPS[@]}"
  echo "Do NOT block 178.62.1.140 (server self / Wordfence sync) or 127.0.0.1."
}

# -----------------------------------------------------------------------------
# Nginx: reject common vuln / config-file probes before PHP
cmd_nginx_probes() {
  need_root
  mkdir -p "$BACKUP_DIR"
  local snippet="/etc/nginx/conf.d/00-vuln-probe-block.conf"

  if [[ -f "$snippet" ]]; then
    cp -a "$snippet" "$BACKUP_DIR/"
  fi

  cat > "$snippet" <<'EOF'
# Origin-level rejection of common vulnerability / config probes.
# Loaded from http{} via conf.d — map used by per-app server blocks if included,
# and as a global "if" safe pattern via map → return in server snippets.
#
# Cloudways app vhosts may need:
#   if ($cw_vuln_probe) { return 403; }
# in /home/master/applications/*/conf/nginx.custom (or equivalent include).

map $request_uri $cw_vuln_probe {
    default                         0;
    ~*(?i)^/(\.env|\.git|\.svn|\.htaccess|\.htpasswd)(\b|/)   1;
    ~*(?i)^/(wp-config\.php|wp-config\.bak|wp-config\.old)    1;
    ~*(?i)^/.*(wp-config|config|configuration|local|database)\.(php|bak|old|txt|sql|env|ini|yml|yaml|xml|dist)(\?|$) 1;
    ~*(?i)^/(phpinfo|info|test|debug)\.php(\?|$)              1;
    ~*(?i)^/(vendor/phpunit|phpunit)/                         1;
    ~*(?i)^/(xmlrpc\.php)(\?|$)                               1;
    ~*(?i)^/\.well-known/(?!acme-challenge).*(\.php)          1;
    ~*(?i)/(ads\.txt|appsettings\.json|web\.config)(\?|$)     0; # leave ads.txt
    ~*(?i)/(web\.config|appsettings\.json)(\?|$)              1;
}
EOF

  # Install per-app custom rule for every active application
  local u custom
  for u in $(list_sysusers); do
    custom="/home/master/applications/${u}/conf/nginx.custom"
    mkdir -p "$(dirname "$custom")"
    if [[ -f "$custom" ]]; then
      cp -a "$custom" "$BACKUP_DIR/nginx.custom.${u}"
    fi
    if [[ -f "$custom" ]] && grep -q 'cw_vuln_probe' "$custom" 2>/dev/null; then
      echo "OK  $u already has cw_vuln_probe rule"
      continue
    fi
    cat >> "$custom" <<'EOF'

# Block vuln/config probes before PHP (server 110523 hardening)
if ($cw_vuln_probe) { return 403; }
EOF
    chown master:master "$custom" 2>/dev/null || true
    echo "OK  appended probe block -> $custom"
  done

  nginx -t && systemctl reload nginx
  echo "Nginx probe map: $snippet"
  echo "Effective: \$cw_vuln_probe → 403 in each app nginx.custom"
}

# -----------------------------------------------------------------------------
cmd_cf_bypass() {
  need_root
  echo "=== Cloudflare origin-bypass check ==="
  echo "1) Direct-to-origin (Host header = public domain, IP = server):"
  echo "   Look for hits where CF-Connecting-IP / CF-Ray absent in access logs."
  echo
  local u log
  for u in $(list_sysusers); do
    log=$(ls /home/master/applications/"$u"/logs/nginx-app.status.log 2>/dev/null | head -1 || true)
    [[ -n "$log" ]] || continue
    echo "--- $u ($(domain_for "$u")) ---"
    echo "Top non-CF-looking client IPs hitting probe paths (last 5k lines):"
    # status log typically: IP - - [date] "METHOD URI PROTO" status ...
    tail -n 5000 "$log" 2>/dev/null \
      | awk 'tolower($0) ~ /(\.env|wp-config|phpunit|xmlrpc\.php|\.git\/|phpinfo)/ {print $1}' \
      | sort | uniq -c | sort -nr | head -n 8 || true
  done

  echo
  echo "2) Alternative app domains (cloudwaysapps.com / aliases) skipping CF:"
  for u in $(list_sysusers); do
    echo "== $u =="
    grep -E 'server_name|server_alias' \
      /home/master/applications/"$u"/conf/server.nginx \
      /home/master/applications/"$u"/conf/*.nginx 2>/dev/null | head -n 20 || true
  done

  echo
  echo "3) Recommend: Cloudflare Authenticated Origin Pulls OR iptables/csf allowlist"
  echo "   of Cloudflare IP ranges only on :80/:443 (blocks direct scanner→origin)."
  echo "   Cloudflare IPs: https://www.cloudflare.com/ips/"
}

# -----------------------------------------------------------------------------
cmd_verify() {
  need_root
  echo "=== VERIFY $(date -u) ==="
  echo "-- Global extras --"
  cat "$GLOBAL_FPM_EXTRAS" 2>/dev/null || true
  echo
  echo "-- Per-pool max_children (effective grep) --"
  grep -rH --include='*.conf' '^pm.max_children' /etc/php/*/fpm/pool.d/ 2>/dev/null | sort
  echo
  echo "-- Sum of pm.max_children across pool.d (includes overrides; last wins per pool) --"
  # Rough: unique pool section last max_children — show raw sum of all directives as upper bound
  awk -F= '/^pm\.max_children/ {gsub(/ /,"",$2); s+=$2}
    END{print "raw_directive_sum=" s+0 " (if overrides coexist with base, prefer discover after reload)"}' \
    /etc/php/*/fpm/pool.d/*.conf 2>/dev/null
  echo
  uptime
  free -h
  echo
  for svc in nginx apache2 mariadb redis-server php7.4-fpm php8.4-fpm; do
    systemctl list-unit-files "${svc}.service" &>/dev/null || continue
    printf "%-16s %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo n/a)"
  done
  echo
  ps -eo rss,args | awk '/php-fpm: pool /{a[$NF]+=$1;n[$NF]++}
    END{for(p in a) printf "%-16s %3d workers  %6.0f MiB\n", p, n[p], a[p]/1024}
  ' | sort -k4 -nr | head -n 15
}

usage() {
  sed -n '2,35p' "$0"
  echo "Commands: discover | recover | block-abuse | apply-global | apply-pools | apply-cgroup | nginx-probes | cf-bypass | verify"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    discover)      cmd_discover ;;
    recover)       cmd_recover ;;
    block-abuse)   cmd_block_abuse ;;
    apply-global)  cmd_apply_global ;;
    apply-pools)   cmd_apply_pools ;;
    apply-cgroup)  cmd_apply_cgroup ;;
    nginx-probes)  cmd_nginx_probes ;;
    cf-bypass)     cmd_cf_bypass ;;
    verify)        cmd_verify ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
