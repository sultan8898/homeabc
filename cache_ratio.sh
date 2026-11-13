#!/bin/bash
# Cache effectiveness: backend PHP share vs frontend traffic (last N lines).
#
# Usage: ./cache_ratio.sh APP [N] [--include-gz]

if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    echo "Do not pipe this script to bash. Run install_case_tools.sh first." >&2
    exit 1
fi
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/case_tools_load.sh"
set -euo pipefail

APP="${1:-}"
N="${2:-2000}"
INCLUDE_GZ=0
[[ "${2:-}" == "--include-gz" ]] && { N=2000; INCLUDE_GZ=1; }
[[ "${3:-}" == "--include-gz" ]] && INCLUDE_GZ=1

[[ -n "$APP" ]] || { echo "Usage: $0 APP [N] [--include-gz]" >&2; exit 1; }

case_resolve_app "$APP" || exit 1

echo "=========================================================="
echo " CACHE RATIO: $APP ($DOMAIN) — last $N lines"
echo "=========================================================="

fe=0 be=0
if [[ -f "$NGINX_STATUS_LOG" ]]; then
    fe=$(case_log_tail "$NGINX_STATUS_LOG" "$N" "$INCLUDE_GZ" | wc -l | tr -d ' ')
fi
if [[ -f "$ACCESS_LOG" ]]; then
    be=$(case_log_tail "$ACCESS_LOG" "$N" "$INCLUDE_GZ" | wc -l | tr -d ' ')
fi

echo "Frontend (nginx-app.status.log) lines: $fe"
echo "Backend  (PHP) lines:                  $be"

if [[ "$fe" -gt 0 ]]; then
    pct=$(awk -v b="$be" -v f="$fe" 'BEGIN { printf "%.1f", (b/f)*100 }')
    echo ""
    echo "PHP/backend share of frontend hits: ${pct}%"
    echo "  (Low % with healthy traffic => most requests served from cache/CDN.)"
    echo "  (High % => cache bypass, dynamic URLs, or crawler hitting uncacheable paths.)"
else
    echo "No frontend log lines to compare."
fi

if [[ -f "$NGINX_STATUS_LOG" && -f "$ACCESS_LOG" ]]; then
    echo ""
    echo "Time window overlap (first/last timestamp in sample):"
    case_log_tail "$NGINX_STATUS_LOG" "$N" "$INCLUDE_GZ" | awk 'NR==1{f=substr($4,2,20)} END{print "  Frontend: " f " -> " substr($4,2,20)}'
    case_log_tail "$ACCESS_LOG" "$N" "$INCLUDE_GZ" | awk 'NR==1{f=substr($4,2,20)} END{print "  Backend:  " f " -> " substr($4,2,20)}'
    echo "  (Backend window ~ frontend window => PHP handling most traffic in that period.)"
fi

if [[ -f "$ACCESS_LOG" && "$be" -gt 0 ]]; then
    qs=$(case_log_tail "$ACCESS_LOG" "$N" "$INCLUDE_GZ" | awk '{print $7}' | awk -F'?' 'NF>1{c++} END{print c+0}')
    echo ""
    echo "Backend hits with query strings: $qs / $be ($(awk -v q="$qs" -v b="$be" 'BEGIN{if(b>0) printf "%.0f", q/b*100; else print 0}')%)"
fi

# Optional cache headers if present in extended log format (field varies; common after status)
if [[ -f "$NGINX_STATUS_LOG" ]]; then
    echo ""
    echo "X-Cache / cache header tokens (if logged in line):"
    case_log_tail "$NGINX_STATUS_LOG" "$N" "$INCLUDE_GZ" | grep -oiE 'HIT|MISS|BYPASS|X-Cache' | sort | uniq -c | sort -nr | head -n 10 || echo "  (none found — log format may not include cache headers)"
fi
