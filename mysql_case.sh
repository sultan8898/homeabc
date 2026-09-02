#!/bin/bash
# MySQL incident drill-down: live processlist + slow query tail.
#
# Usage: ./mysql_case.sh [--running-seconds N] [--slow-top N] [--db NAME]

set -euo pipefail

RUNNING_SEC=5
SLOW_TOP=15
FILTER_DB=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --running-seconds) RUNNING_SEC="$2"; shift 2 ;;
        --slow-top) SLOW_TOP="$2"; shift 2 ;;
        --db) FILTER_DB="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

echo "=========================================================="
echo " MYSQL CASE  $(date)"
echo "=========================================================="

if ! command -v mysql >/dev/null 2>&1; then
    echo "mysql client not found."
    exit 1
fi

echo ""
echo "--- Global status ---"
mysql -e "SHOW GLOBAL STATUS LIKE 'Threads_running'; SHOW GLOBAL STATUS LIKE 'Threads_connected'; SHOW GLOBAL STATUS LIKE 'Slow_queries';" 2>/dev/null \
    || echo "mysql status query failed (credentials/socket?)"

echo ""
echo "--- Queries running longer than ${RUNNING_SEC}s (non-Sleep) ---"
mysql -e "
SELECT ID, USER, DB, TIME, STATE, LEFT(INFO, 120) AS QUERY_HEAD
FROM information_schema.PROCESSLIST
WHERE COMMAND != 'Sleep' AND TIME >= ${RUNNING_SEC}
ORDER BY TIME DESC
LIMIT 25;" 2>/dev/null || true

if [[ -n "$FILTER_DB" ]]; then
    echo ""
    echo "--- Filtered to DB=$FILTER_DB ---"
    mysql -e "
SELECT ID, USER, TIME, STATE, LEFT(INFO, 120) AS QUERY_HEAD
FROM information_schema.PROCESSLIST
WHERE DB = '${FILTER_DB}' AND COMMAND != 'Sleep'
ORDER BY TIME DESC
LIMIT 20;" 2>/dev/null || true
fi

SLOW_LOG="/var/log/mysql/slow-query.log"
if [[ ! -f "$SLOW_LOG" ]]; then
    for p in /var/log/mysql/mysql-slow.log /var/log/mysqld-slow.log; do
        [[ -f "$p" ]] && SLOW_LOG="$p" && break
    done
fi

echo ""
echo "--- Slow query log: top ${SLOW_TOP} by Query_time (tail 10000 lines) ---"
if [[ -f "$SLOW_LOG" ]]; then
    tail -n 10000 "$SLOW_LOG" 2>/dev/null | awk '
    /^# Query_time:/ { q_time=$3; q_db=""; }
    /^# User@Host:/ { }
    /^use / { q_db=$2; gsub(/;/,"",q_db); }
    /^[a-zA-Z]/ && !/^SET timestamp/ && !/^use / {
        if (q_time != "") {
            query=substr($0, 1, 100)
            printf "%05.2f Secs  db=%s  %s...\n", q_time, q_db, query
            q_time=""
        }
    }' | sort -nr | head -n "$SLOW_TOP"
else
    echo "Slow log not found (enable slow_query_log on server)."
fi

echo ""
echo "--- InnoDB status (truncated) ---"
mysql -e "SHOW ENGINE INNODB STATUS\G" 2>/dev/null | head -n 40 || true
