#!/bin/bash
# =============================================================================
# MySQL / MariaDB remote sync connection investigation (Cloudways)
#
# Use during or immediately after a warehouse (e.g. GCP Cloud Run) sync failure.
# Run as root on the database server. Optional UTC window for log correlation.
#
# Usage:
#   ./mysql_remote_sync_investigation.sh
#   ./mysql_remote_sync_investigation.sh 2026-10-15T17:27:50 2026-10-15T17:28:10
#   CLIENT_IP=34.162.106.181 ./mysql_remote_sync_investigation.sh ...
# =============================================================================

set -euo pipefail

CLIENT_IP="${CLIENT_IP:-34.162.106.181}"
WHITELIST_EXTRA="${WHITELIST_EXTRA:-209.71.89.195 209.71.89.253 204.93.228.4}"
WINDOW_START="${1:-}"
WINDOW_END="${2:-}"

MYSQL="${MYSQL:-mysql}"
ERR_LOG="${ERR_LOG:-/var/log/mysql/error.log}"
if [[ ! -f "$ERR_LOG" && -f /var/log/mysqld.log ]]; then
  ERR_LOG="/var/log/mysqld.log"
fi

section() {
  echo ""
  echo "======================================================================"
  echo " $1"
  echo "======================================================================"
}

run_mysql() {
  "$MYSQL" -N -e "$1" 2>/dev/null || echo "(mysql query failed: $1)"
}

section "Context"
echo "Host: $(hostname -f 2>/dev/null || hostname)"
echo "UTC now: $(date -u '+%Y-%m-%d %H:%M:%S')"
echo "Client IP under test: $CLIENT_IP"
if [[ -n "$WINDOW_START" && -n "$WINDOW_END" ]]; then
  echo "Log window (UTC): $WINDOW_START .. $WINDOW_END"
fi

section "1) Host cache / connect errors (max_connect_errors)"
run_mysql "SHOW VARIABLES LIKE 'max_connect_errors';"
run_mysql "SHOW VARIABLES LIKE 'skip_name_resolve';"
run_mysql "SHOW GLOBAL STATUS LIKE 'Connection_errors%';"
run_mysql "SHOW GLOBAL STATUS LIKE 'Aborted_connects';"

# MariaDB 10.x+ performance_schema.host_cache (MySQL 8 uses similar)
if run_mysql "SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA='performance_schema' AND TABLE_NAME='host_cache' LIMIT 1;" | grep -q 1; then
  echo ""
  echo "--- performance_schema.host_cache for $CLIENT_IP ---"
  run_mysql "
    SELECT IP, HOST, HOST_VALIDATED, SUM_CONNECT_ERRORS, COUNT_HOST_BLOCKED_ERRORS,
           COUNT_AUTHENTICATION_ERRORS, COUNT_NAMEINFO_TRANSIENT_ERRORS,
           COUNT_NAMEINFO_PERMANENT_ERRORS, COUNT_PROXY_USER_ERRORS,
           COUNT_HANDSHAKE_ERRORS, FIRST_SEEN, LAST_SEEN
    FROM performance_schema.host_cache
    WHERE IP = INET_ATON('$CLIENT_IP')
       OR HOST LIKE '%$CLIENT_IP%'
    LIMIT 5;"
else
  echo "(performance_schema.host_cache not available)"
fi

section "2) Connection limits and timeout stack (all config sources)"
echo "--- Effective globals ---"
run_mysql "SHOW GLOBAL VARIABLES WHERE Variable_name IN (
  'max_connections','max_user_connections','wait_timeout','interactive_timeout',
  'connect_timeout','net_read_timeout','net_write_timeout','max_allowed_packet',
  'max_connect_errors','thread_cache_size','back_log');"

echo ""
echo "--- All wait_timeout / interactive_timeout in /etc/mysql (last value wins at runtime; list every file) ---"
grep -RniE 'wait_timeout|interactive_timeout|max_user_connections|max_connections' /etc/mysql/ 2>/dev/null || true

section "3) Live connections from warehouse IP / user breakdown"
run_mysql "
SELECT SUBSTRING_INDEX(HOST, ':', 1) AS client_host, USER, db,
       SUM(COMMAND = 'Sleep') AS sleeping,
       SUM(COMMAND != 'Sleep') AS active,
       COUNT(*) AS total,
       MAX(TIME) AS max_time_sec
FROM information_schema.PROCESSLIST
GROUP BY client_host, USER, db
ORDER BY total DESC
LIMIT 25;"

echo ""
echo "--- Connections from $CLIENT_IP ---"
run_mysql "
SELECT ID, USER, db, COMMAND, TIME, STATE, LEFT(INFO, 120) AS query_head
FROM information_schema.PROCESSLIST
WHERE HOST LIKE '${CLIENT_IP}%'
ORDER BY TIME DESC;"

section "4) Aborted connection counters"
run_mysql "SHOW GLOBAL STATUS LIKE 'Aborted_%';"
run_mysql "SHOW GLOBAL STATUS LIKE 'Max_used_connections';"
run_mysql "SHOW GLOBAL STATUS LIKE 'Threads_%';"

section "5) MariaDB error log (recent + optional window)"
if [[ -f "$ERR_LOG" ]]; then
  echo "--- Last 30 lines mentioning client IP, abort, block, handshake, OOM ---"
  grep -iE "$CLIENT_IP|Aborted connection|Got an error reading|max_user_connections|Host .* is blocked|handshake|SSL|Out of memory|killed" "$ERR_LOG" 2>/dev/null | tail -n 30 || echo "(no matching lines in tail search)"

  if [[ -n "$WINDOW_START" && -n "$WINDOW_END" ]]; then
    # Normalize ISO timestamps to syslog-style if log uses local time, try both UTC grep on raw ISO substring
    ISO_DATE="${WINDOW_START:0:10}"
    echo ""
    echo "--- Lines on $ISO_DATE near window (manual TZ check; MariaDB often logs local time) ---"
    grep "$ISO_DATE" "$ERR_LOG" 2>/dev/null | tail -n 200 || true
  fi
else
  echo "Error log not found at $ERR_LOG"
fi

section "6) Firewall / Imunify360 (3306, client IP)"
if command -v imunify360-agent >/dev/null 2>&1; then
  echo "--- Imunify360 whitelist grep (client + known NAT IPs) ---"
  for ip in "$CLIENT_IP" $WHITELIST_EXTRA; do
    imunify360-agent ip-list list --json 2>/dev/null | grep -F "$ip" && echo "  listed: $ip" || echo "  not found in ip-list json: $ip"
  done
  echo ""
  echo "--- Recent Imunify / iptables denials for 3306 or client IP (syslog, last 50) ---"
  grep -iE "imunify|$CLIENT_IP|3306|REJECT|DROP" /var/log/syslog 2>/dev/null | tail -n 50 || true
else
  echo "(imunify360-agent not installed or not in PATH)"
fi

if command -v csf >/dev/null 2>&1; then
  echo ""
  echo "--- CSF grep for client IP ---"
  csf -g "$CLIENT_IP" 2>/dev/null | head -n 40 || true
fi

section "7) Suggested capture during next failed sync (run in parallel terminal)"
cat <<EOF
# On server (requires root), during sync — replace TIMESTAMP:
tcpdump -ni any host $CLIENT_IP and port 3306 -w /tmp/mysql-${CLIENT_IP}-\$(date -u +%Y%m%dT%H%M%SZ).pcap

# Enable short general log burst (high volume; disable after test):
# $MYSQL -e "SET GLOBAL general_log=ON; SET GLOBAL log_output='FILE';"
# ... run failing sync ...
# $MYSQL -e "SET GLOBAL general_log=OFF;"

# After failure, re-run this script with UTC window:
# CLIENT_IP=$CLIENT_IP $0 'YYYY-MM-DDTHH:MM:SS' 'YYYY-MM-DDTHH:MM:SS'
EOF

section "Done"
