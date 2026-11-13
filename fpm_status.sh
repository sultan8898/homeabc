#!/bin/bash
# PHP-FPM worker pressure: processes, pool hints, recent upstream errors.
#
# Usage: ./fpm_status.sh [app|all]

if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    echo "Do not pipe this script to bash. Run install_case_tools.sh first." >&2
    exit 1
fi
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/case_tools_load.sh"
set -euo pipefail

TARGET="${1:-all}"
if [[ "$TARGET" == "all" ]]; then
    APPS=$(case_list_apps)
else
    APPS="$TARGET"
fi

echo "=========================================================="
echo " PHP-FPM STATUS  $(date)"
echo "=========================================================="
echo ""
echo "--- Load / memory ---"
uptime
free -h 2>/dev/null || true

echo ""
echo "--- php-fpm processes (count by pool/cmd) ---"
ps -eo comm= 2>/dev/null | grep -E 'php-fpm|php[0-9.]*-fpm' | sort | uniq -c | sort -nr | head -n 20

echo ""
echo "--- Top CPU php-fpm workers (live) ---"
ps -eo pcpu,pmem,pid,args --sort=-pcpu 2>/dev/null | grep -E 'php-fpm: pool|php-fpm' | head -n 15

fpm_one_app() {
    local app="$1"
    case_resolve_app "$app" 2>/dev/null || return
    echo ""
    echo "----------------------------------------------------------"
    echo " App: $app ($DOMAIN)"

    local pool_conf=""
    for c in "$APP_DIR/conf/fpm-pool.conf" "$APP_DIR/conf/php-fpm.conf" "$APP_DIR/conf/custom-php-fpm.conf"; do
        [[ -f "$c" ]] && pool_conf="$c" && break
    done
    if [[ -n "$pool_conf" ]]; then
        echo " Pool config: $pool_conf"
        grep -E '^(pm\.|pm |listen|request_terminate|max_children|max_requests)' "$pool_conf" 2>/dev/null | head -n 20
    else
        echo " Pool config: (not found under conf/)"
    fi

    if [[ -d "$LOG_DIR" ]]; then
        echo " Recent upstream / timeout errors (error logs):"
        tail -n 500 "$LOG_DIR"/*error.log 2>/dev/null \
            | grep -oiE 'upstream timed out|connect\(\) failed|no live upstreams|worker_connections|limiting requests' \
            | sort | uniq -c | sort -nr | head -n 8 || echo "  (none in tail)"
    fi

    if [[ -f "$NGINX_STATUS_LOG" ]]; then
        local n499
        n499=$(tail -n 2000 "$NGINX_STATUS_LOG" 2>/dev/null | awk '$9==499' | wc -l | tr -d ' ')
        echo " 499 count in last 2000 frontend lines: $n499"
    fi
}

for app in $APPS; do
    fpm_one_app "$app"
done

echo ""
echo "Tip: 499 spikes + 'upstream timed out' => raise pm.max_children only after finding PHP/slow-query cause."
