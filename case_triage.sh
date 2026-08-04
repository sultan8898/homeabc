#!/bin/bash
# Quick verdict for recurring incident patterns (companion to all_check.sh).
#
# Usage: ./case_triage.sh [N] [app|all]
#   N default 2000; app name or "all" (default all)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=case_lib.sh
source "$SCRIPT_DIR/case_lib.sh"

N=2000
TARGET="all"
if [[ $# -eq 0 ]]; then
    :
elif [[ "$1" =~ ^[0-9]+$ ]]; then
    N="$1"
    TARGET="${2:-all}"
else
    TARGET="$1"
    N="${2:-2000}"
    [[ "$2" =~ ^[0-9]+$ ]] && N="$2"
fi

if [[ "$TARGET" == "all" ]]; then
    APPS=$(case_list_apps)
else
    APPS="$TARGET"
fi

score_line() {
    local label="$1"
    local score="$2"
    local detail="$3"
    printf "  [%3d] %s\n       %s\n" "$score" "$label" "$detail"
}

triage_app() {
    local app="$1"
    case_resolve_app "$app" 2>/dev/null || return
    [[ -f "$ACCESS_LOG" ]] || return

    local be
    be=$(case_log_tail "$ACCESS_LOG" "$N" 0)
    [[ -n "$be" ]] || return

    echo ""
    echo "=========================================================="
    echo " TRIAGE: $app  ($DOMAIN)  — last $N backend hits"
    echo "=========================================================="

    local unique_ips total qs tracker facets cron_ep ajax_ep
    total=$(echo "$be" | wc -l | tr -d ' ')
    unique_ips=$(echo "$be" | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
    qs=$(echo "$be" | awk '{print $7}' | awk -F'?' 'NF>1{c++} END{print c+0}')
    tracker=$(echo "$be" | awk '{print $7}' | grep -cE '[?&](gclid|fbclid|utm_|noamp|nocache|ver|v)=' || true)
    facets=$(echo "$be" | awk '{print $7}' | grep -ciE '([?&](filter_|orderby=|min_price|max_price|tribe-bar-date|product_cat|pa_))|(/product-tag/|/product-category/)' || true)
    cron_ep=$(echo "$be" | grep -c 'wp-cron.php' || true)
    ajax_ep=$(echo "$be" | grep -c 'admin-ajax.php' || true)

    local fe_span be_span
    if [[ -f "$NGINX_STATUS_LOG" ]]; then
        local fe
        fe=$(case_log_tail "$NGINX_STATUS_LOG" "$N" 0)
        fe_span=$(echo "$fe" | awk 'NR==1{f=substr($4,2,20)} END{print f " -> " substr($4,2,20)}')
    else
        fe_span="n/a"
    fi
    be_span=$(echo "$be" | awk 'NR==1{f=substr($4,2,20)} END{print f " -> " substr($4,2,20)}')

    local sat499=0
    if [[ -f "$NGINX_STATUS_LOG" ]]; then
        sat499=$(case_log_tail "$NGINX_STATUS_LOG" "$N" 0 | awk '$9==499' | wc -l | tr -d ' ')
    fi

    local top_subnet_ips top_subnet_hits ua_spread
    read -r top_subnet_hits top_subnet_ips _ < <(
        echo "$be" | awk '{split($1,o,"."); sn=o[1]"."o[2]"."o[3]".0/24"; c[sn]++; k=sn SUBSEP $1; if(!s[k]++) u[sn]++}
            END {for (x in c) print c[x], u[x], x}' | sort -nr | head -n 1
    )
    top_subnet_hits=${top_subnet_hits:-0}
    top_subnet_ips=${top_subnet_ips:-0}

    read -r ua_hits ua_ips _ < <(
        echo "$be" | awk -F'"' '{split($1,a," "); ip=a[1]; ua=$6; c[ua]++; k=ua SUBSEP ip; if(!s[k]++) ips[ua]++}
            END {for (u in c) if (c[u]>=20) print c[u], ips[u], u}' | sort -nr | head -n 1
    )
    ua_hits=${ua_hits:-0}
    ua_ips=${ua_ips:-0}

    declare -a verdicts=()

    # Scoring heuristics (higher = more likely)
    local s_swarm=0 s_cache=0 s_facet=0 s_cron=0 s_sat=0 s_ajax=0

    if [[ "$total" -gt 0 ]]; then
        local ip_ratio=$(( unique_ips * 100 / total ))
        if [[ "$ip_ratio" -ge 70 && "$unique_ips" -ge 200 ]]; then
            s_swarm=$(( ip_ratio / 2 ))
            verdicts+=("proxy_swarm")
        fi
        if [[ "$top_subnet_ips" -ge 80 && "$top_subnet_hits" -ge 150 ]]; then
            s_swarm=$(( s_swarm + 25 ))
            verdicts+=("subnet_rotation")
        fi
        if [[ "$ua_ips" -ge 100 && "$ua_hits" -ge 200 ]]; then
            s_swarm=$(( s_swarm + 30 ))
            verdicts+=("ua_swarm")
        fi
        if [[ "$qs" -ge $(( total * 40 / 100 )) ]]; then
            s_cache=$(( qs * 100 / total / 2 ))
            verdicts+=("query_string_cache_bypass")
        fi
        if [[ "$tracker" -ge $(( total * 15 / 100 )) ]]; then
            s_cache=$(( s_cache + 20 ))
            verdicts+=("tracking_params")
        fi
        if [[ "$facets" -ge 50 ]]; then
            s_facet=$(( facets / 2 ))
            [[ "$s_facet" -gt 50 ]] && s_facet=50
            verdicts+=("faceted_nav_crawl")
        fi
        if [[ "$cron_ep" -ge 80 ]]; then
            s_cron=$(( cron_ep / 2 ))
            verdicts+=("wp_cron_pressure")
        fi
        if [[ "$ajax_ep" -ge $(( total * 20 / 100 )) ]]; then
            s_ajax=$(( ajax_ep * 100 / total / 2 ))
            verdicts+=("admin_ajax_flood")
        fi
    fi

    if [[ "$sat499" -ge 30 ]]; then
        s_sat=$(( sat499 / 2 ))
        [[ "$s_sat" -gt 50 ]] && s_sat=50
        verdicts+=("499_saturation")
    fi

    local ip_pct=0
    [[ "$total" -gt 0 ]] && ip_pct=$(( unique_ips * 100 / total ))

    echo "Signals:"
    echo "  Unique IPs: $unique_ips / $total backend hits (${ip_pct}% unique)"
    echo "  Query-string hits: $qs ($tracker with tracker/cache-buster params)"
    echo "  Facet/archive pattern hits: $facets"
    echo "  wp-cron.php hits: $cron_ep | admin-ajax.php: $ajax_ep"
    echo "  Frontend time span: $fe_span"
    echo "  Backend  time span: $be_span  (similar span => cache bypass at scale)"
    echo "  499 count (frontend window): $sat499"
    [[ "$top_subnet_hits" -gt 0 ]] && echo "  Top /24: $top_subnet_hits hits from $top_subnet_ips IPs"
    [[ "$ua_hits" -gt 0 ]] && echo "  Top UA swarm: $ua_hits hits from $ua_ips IPs"

    echo ""
    echo "Likely case types (score):"
    score_line "499 / FPM saturation" "$s_sat" "Many 499s in frontend log during window"
    score_line "Residential proxy / IP swarm" "$s_swarm" "High unique IP ratio, /24 or UA spread"
    score_line "Cache bypass (QS / trackers)" "$s_cache" "High % of PHP hits with query strings"
    score_line "Faceted nav / Woo crawl" "$s_facet" "Filter/category/archive URL patterns"
    score_line "wp-cron stampede" "$s_cron" "Heavy wp-cron.php on backend log"
    score_line "admin-ajax pressure" "$s_ajax" "Large share of hits to admin-ajax.php"

    local best=0 best_name="(no strong signal — run all_check.sh with higher N)"
    if [[ "$s_sat" -ge "$best" ]]; then best=$s_sat; best_name="499 / FPM saturation"; fi
    if [[ "$s_swarm" -gt "$best" ]]; then best=$s_swarm; best_name="Residential proxy / IP swarm"; fi
    if [[ "$s_cache" -gt "$best" ]]; then best=$s_cache; best_name="Cache bypass (query strings)"; fi
    if [[ "$s_facet" -gt "$best" ]]; then best=$s_facet; best_name="Faceted nav / Woo crawl"; fi
    if [[ "$s_cron" -gt "$best" ]]; then best=$s_cron; best_name="wp-cron stampede"; fi
    if [[ "$s_ajax" -gt "$best" ]]; then best=$s_ajax; best_name="admin-ajax pressure"; fi

    echo ""
    echo ">>> PRIMARY HYPOTHESIS: $best_name (score $best)"
    if [[ ${#verdicts[@]} -gt 0 ]]; then
        echo ">>> Tags: $(printf '%s ' "${verdicts[@]}" | sed 's/ $//')"
    fi
    echo ">>> Next: case_slice.sh for the spike minute | case_ip.sh for top IP | cache_ratio.sh | fpm_status.sh"
}

echo "SERVER: $(uptime)"
echo "OOM (last 3):"
dmesg -T 2>/dev/null | grep -iE "oom-kill|out of memory" | tail -n 3 || true

for app in $APPS; do
    triage_app "$app"
done

echo ""
echo "=========================================================="
echo " GLOBAL wp-cron per minute (all apps, last $N lines each):"
tail -q -n "$N" "$APPS_BASE"/*/logs/backend_*.cloudwaysapps.com.access.log 2>/dev/null \
    | grep 'wp-cron.php' | awk '{print substr($4,2,17)}' | sort | uniq -c | sort -nr | head -n 5 || true
echo "=========================================================="
