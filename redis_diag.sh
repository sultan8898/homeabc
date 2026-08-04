#!/bin/bash
# Redis / object cache quick health (server-wide + optional per-app WP Redis).
#
# Usage: ./redis_diag.sh [app]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=case_lib.sh
source "$SCRIPT_DIR/case_lib.sh"

APP="${1:-}"

echo "=========================================================="
echo " REDIS DIAG  $(date)"
echo "=========================================================="

if ! command -v redis-cli >/dev/null 2>&1; then
    echo "redis-cli not found on PATH."
    exit 1
fi

if redis-cli ping 2>/dev/null | grep -q PONG; then
    echo "PING: OK"
else
    echo "PING: FAILED (is Redis running on 127.0.0.1:6379?)"
fi

echo ""
echo "--- INFO (subset) ---"
redis-cli INFO memory 2>/dev/null | grep -E '^(used_memory_human|maxmemory_human|mem_fragmentation_ratio|used_memory_peak_human)' || true
redis-cli INFO stats 2>/dev/null | grep -E '^(instantaneous_ops_per_sec|keyspace_hits|keyspace_misses|evicted_keys|rejected_connections)' || true
redis-cli INFO clients 2>/dev/null | grep -E '^(connected_clients|blocked_clients)' || true

hits=$(redis-cli INFO stats 2>/dev/null | awk -F: '/^keyspace_hits/{gsub(/\r/,""); print $2}')
miss=$(redis-cli INFO stats 2>/dev/null | awk -F: '/^keyspace_misses/{gsub(/\r/,""); print $2}')
if [[ -n "$hits" && -n "$miss" ]]; then
    total=$(( hits + miss ))
    if [[ "$total" -gt 0 ]]; then
        echo ""
        echo "Hit ratio (since restart): $(awk -v h="$hits" -v t="$total" 'BEGIN{printf "%.2f%%", h/t*100}') ($hits hits / $total ops)"
    fi
fi

echo ""
echo "--- DBSIZE ---"
redis-cli DBSIZE 2>/dev/null || true

if [[ -n "$APP" ]]; then
    wp_root=$(case_find_wp_root "$APP")
    echo ""
    echo "--- WP Redis ($APP) ---"
    if [[ -n "$wp_root" && -f "$wp_root/wp-config.php" ]]; then
        if grep -q WP_REDIS_CONFIG "$wp_root/wp-config.php" 2>/dev/null; then
            echo "WP_REDIS_CONFIG: present in wp-config.php"
        else
            echo "WP_REDIS_CONFIG: not found in wp-config.php"
        fi
        if command -v wp >/dev/null 2>&1; then
            site_url=$(case_primary_site_url "$APP" 2>/dev/null || true)
            if [[ -n "$site_url" ]]; then
                (cd "$wp_root" && wp redis status --allow-root --url="$site_url" 2>/dev/null) || \
                    (cd "$wp_root" && wp redis status --allow-root 2>/dev/null) || echo "  wp redis status: unavailable"
            fi
        fi
    else
        echo "No WordPress root found for $APP"
    fi
else
    echo ""
    echo "Per-app WP Redis: run $0 <app_name>"
fi
