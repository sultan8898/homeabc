#!/bin/bash
# Drill-down: everything one IP did against an app (frontend + backend logs).
#
# Usage: ./case_ip.sh APP IP [N] [--include-gz]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=case_lib.sh
source "$SCRIPT_DIR/case_lib.sh"

APP="${1:-}"
IP="${2:-}"
N="${3:-2000}"
INCLUDE_GZ=0

if [[ "${3:-}" == "--include-gz" ]]; then
    N=2000
    INCLUDE_GZ=1
fi
for arg in "$@"; do
    [[ "$arg" == "--include-gz" ]] && INCLUDE_GZ=1
done

[[ -n "$APP" && -n "$IP" ]] || {
    echo "Usage: $0 APP IP [N] [--include-gz]" >&2
    exit 1
}

case_resolve_app "$APP" || exit 1

echo "=========================================================="
echo " IP DRILL-DOWN: $IP on $APP ($DOMAIN)"
echo " Last $N lines per log (use higher N during incidents)"
echo "=========================================================="

analyze_log() {
    local label="$1"
    local path="$2"
    [[ -f "$path" ]] || { echo -e "\n[$label] not found"; return; }

    local tmp
    tmp=$(mktemp)
    case_log_tail "$path" "$N" "$INCLUDE_GZ" | awk -v ip="$IP" '$1 == ip {print}' > "$tmp"
    local c
    c=$(wc -l < "$tmp" | tr -d ' ')
    echo -e "\n--- $label ($c hits) ---"
    [[ "$c" -eq 0 ]] && { rm -f "$tmp"; return; }

    echo "Status mix:"
    awk '{print $9}' "$tmp" | grep -E '^[1-5][0-9]{2}$' | sort | uniq -c | sort -nr

    echo -e "\nTop paths:"
    awk '{print $7}' "$tmp" | cut -d? -f1 | sort | uniq -c | sort -nr | head -n 15

    echo -e "\nTop paths (with query string):"
    awk '{print $7}' "$tmp" | sort | uniq -c | sort -nr | head -n 10

    echo -e "\nMethods:"
    awk '{print $6}' "$tmp" | tr -d '"' | sort | uniq -c | sort -nr

    echo -e "\nReferrers:"
    awk -F'"' '{print $4}' "$tmp" | grep -v '^-$' | sort | uniq -c | sort -nr | head -n 10

    echo -e "\nUser-Agent:"
    awk -F'"' '{print $6}' "$tmp" | sort | uniq -c | sort -nr | head -n 5

    echo -e "\nSample lines (newest 5):"
    tail -n 5 "$tmp"

    rm -f "$tmp"
}

analyze_log "FRONTEND" "$NGINX_STATUS_LOG"
analyze_log "BACKEND (PHP)" "$ACCESS_LOG"
