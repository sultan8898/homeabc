#!/bin/bash
# wp-cron / Action Scheduler audit across Cloudways apps.
#
# Usage: ./cron_audit.sh [app|all]

if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    echo "Do not pipe this script to bash. Run install_case_tools.sh first." >&2
    exit 1
fi
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/case_tools_load.sh"
set -euo pipefail

TARGET="${1:-all}"
WP="${WP_CLI:-/usr/local/bin/wp}"

if [[ "$TARGET" == "all" ]]; then
    APPS=$(case_list_apps)
else
    APPS="$TARGET"
fi

audit_app() {
    local app="$1"
    case_resolve_app "$app" 2>/dev/null || return
    local wp_root
    wp_root=$(case_find_wp_root "$app") || {
        echo ""
        echo "[$app] Not WordPress — skipped"
        return
    }

    local site_url
    site_url=$(case_primary_site_url "$app" 2>/dev/null || echo "")

    echo ""
    echo "=========================================================="
    echo " CRON AUDIT: $app ($DOMAIN)"
    echo " WP root: $wp_root"
    echo "=========================================================="

    if grep -q "DISABLE_WP_CRON" "$wp_root/wp-config.php" 2>/dev/null; then
        grep DISABLE_WP_CRON "$wp_root/wp-config.php" | head -n 2
    else
        echo "DISABLE_WP_CRON: not set (wp-cron may run on web requests)"
    fi

    if [[ -f /etc/ansible/facts.d/wp_cron.fact ]]; then
        echo "Cloudways wp_cron.fact:"
        cat /etc/ansible/facts.d/wp_cron.fact 2>/dev/null | head -n 5
    fi

    if [[ ! -x "$WP" && ! -f "$WP" ]]; then
        echo "WP-CLI not found at $WP"
        return
    fi

    local wp_base=( "$WP" --allow-root --path="$wp_root" )
    [[ -n "$site_url" ]] && wp_base+=( --url="$site_url" )

    echo ""
    echo "Cron schedule (wp cron event list --fields=hook,next_run_relative,recurrence --format=table | head):"
    "${wp_base[@]}" cron event list --fields=hook,next_run_relative,recurrence --format=table 2>/dev/null | head -n 25 \
        || echo "  (wp cron event list failed)"

    echo ""
    echo "Overdue cron timestamps (count):"
    "${wp_base[@]}" eval '$c=0; foreach ( _get_cron_array() as $ts => $hooks ) { if ( $ts <= time() ) { $c++; } } echo "overdue_slots: $c\n";' 2>/dev/null \
        || echo "  (eval skipped)"

    if "${wp_base[@]}" plugin is-active woocommerce 2>/dev/null | grep -q yes; then
        echo ""
        echo "WooCommerce Action Scheduler (pending/failed counts):"
        "${wp_base[@]}" eval '
            global $wpdb;
            $t = $wpdb->prefix . "actionscheduler_actions";
            if ( $wpdb->get_var( $wpdb->prepare("SHOW TABLES LIKE %s", $t) ) === $t ) {
                foreach ( array("pending","in-progress","failed","canceled") as $st ) {
                    $c = $wpdb->get_var( $wpdb->prepare("SELECT COUNT(*) FROM $t WHERE status=%s", $st) );
                    echo "$st: $c\n";
                }
            } else {
                echo "actionscheduler_actions table not found\n";
            }
        ' 2>/dev/null || echo "  (Action Scheduler check failed)"
    fi

    if [[ -f "$ACCESS_LOG" ]]; then
        local cron_hits
        cron_hits=$(tail -n 3000 "$ACCESS_LOG" 2>/dev/null | grep -c 'wp-cron.php' || true)
        echo ""
        echo "wp-cron.php hits in last 3000 backend lines: $cron_hits"
    fi
}

echo "SERVER TIME: $(date)"
echo "WP-CLI: $WP"

for app in $APPS; do
    audit_app "$app"
done

echo ""
echo "=========================================================="
echo " GLOBAL: wp-cron hits per minute (all apps, tail 2000/backend log each)"
tail -q -n 2000 "$APPS_BASE"/*/logs/backend_*.cloudwaysapps.com.access.log 2>/dev/null \
    | grep 'wp-cron.php' | awk '{print substr($4,2,17)}' | sort | uniq -c | sort -nr | head -n 8 || true
echo "=========================================================="
