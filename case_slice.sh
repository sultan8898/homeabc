#!/bin/bash
# Filter nginx/backend access logs by time window (and optional IP, status, URL grep).
#
# Usage:
#   ./case_slice.sh -a APP -d DD/MM/YYYY -f HH:MM -u HH:MM [options]
#
# Options:
#   --log frontend|backend|both   (default: both)
#   --ip IP
#   --status CODE                 (e.g. 499, 502, or 5xx)
#   --grep PAT                    extended grep on request line ($7)
#   --include-gz                  include rotated/gzip siblings
#   --top N                       top lists size (default 10)

if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    echo "Pipe the runner instead:" >&2
    echo '  curl -fsSL https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/cursor/case-investigation-scripts-c2b2/case.sh | bash -s -- slice -a APP ...' >&2
    exit 1
fi
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/case_tools_load.sh"
set -euo pipefail

APP=""
RUN_DATE=""
START_TIME=""
END_TIME=""
LOG_KIND="both"
FILTER_IP=""
FILTER_STATUS=""
GREP_PAT=""
INCLUDE_GZ=0
TOP_N=10

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--app) APP="$2"; shift 2 ;;
        -d|--date) RUN_DATE="$2"; shift 2 ;;
        -f|--from) START_TIME="$2"; shift 2 ;;
        -u|--until) END_TIME="$2"; shift 2 ;;
        --log) LOG_KIND="$2"; shift 2 ;;
        --ip) FILTER_IP="$2"; shift 2 ;;
        --status) FILTER_STATUS="$2"; shift 2 ;;
        --grep) GREP_PAT="$2"; shift 2 ;;
        --include-gz) INCLUDE_GZ=1; shift ;;
        --top) TOP_N="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[[ -n "$APP" && -n "$RUN_DATE" && -n "$START_TIME" && -n "$END_TIME" ]] || usage 1

FROM_KEY=$(case_nginx_time_key "$RUN_DATE" "$START_TIME")
TO_KEY=$(case_nginx_time_key "$RUN_DATE" "$END_TIME")
[[ -n "$FROM_KEY" && -n "$TO_KEY" ]] || { echo "Invalid date/time (use DD/MM/YYYY and HH:MM)" >&2; exit 1; }

case_resolve_app "$APP" || exit 1

echo "=========================================================="
echo " CASE SLICE: $APP  ($DOMAIN)"
echo " Window: $RUN_DATE $START_TIME -> $END_TIME  (log keys $FROM_KEY .. $TO_KEY)"
echo "=========================================================="

slice_file() {
    local label="$1"
    local path="$2"
    [[ -f "$path" ]] || { echo -e "\n[$label] log not found: $path"; return; }

    local tmp
    tmp=$(mktemp)
    case_log_stream "$path" "$INCLUDE_GZ" | awk -v from="$FROM_KEY" -v to="$TO_KEY" '
        {
            t = substr($4, 2, 17)
            if (t < from || t > to) next
            print
        }
    ' > "$tmp"

    local lines
    lines=$(wc -l < "$tmp" | tr -d ' ')
    echo -e "\n--- $label ($path) ---"
    echo "Matching lines: $lines"

    if [[ "$lines" -eq 0 ]]; then
        rm -f "$tmp"
        return
    fi

    if [[ -n "$FILTER_IP" ]]; then
        grep -F "$FILTER_IP" "$tmp" > "${tmp}.f" && mv "${tmp}.f" "$tmp"
        lines=$(wc -l < "$tmp" | tr -d ' ')
        echo "After --ip $FILTER_IP: $lines"
    fi

    if [[ -n "$FILTER_STATUS" ]]; then
        if [[ "$FILTER_STATUS" == "5xx" ]]; then
            awk '$9 ~ /^50/' "$tmp" > "${tmp}.f" && mv "${tmp}.f" "$tmp"
        else
            awk -v s="$FILTER_STATUS" '$9 == s' "$tmp" > "${tmp}.f" && mv "${tmp}.f" "$tmp"
        fi
        lines=$(wc -l < "$tmp" | tr -d ' ')
        echo "After --status $FILTER_STATUS: $lines"
    fi

    if [[ -n "$GREP_PAT" ]]; then
        grep -E "$GREP_PAT" "$tmp" > "${tmp}.f" && mv "${tmp}.f" "$tmp"
        lines=$(wc -l < "$tmp" | tr -d ' ')
        echo "After --grep: $lines"
    fi

    echo -e "\nHits per minute:"
    awk '{print substr($4,2,17)}' "$tmp" | sort | uniq -c | sort -nr | head -n "$TOP_N"

    echo -e "\nStatus breakdown:"
    awk '{print $9}' "$tmp" | grep -E '^[1-5][0-9]{2}$' | sort | uniq -c | sort -nr | head -n "$TOP_N"

    echo -e "\nTop URLs:"
    awk '{print $7}' "$tmp" | cut -d? -f1 | sort | uniq -c | sort -nr | head -n "$TOP_N"

    echo -e "\nTop IPs:"
    awk '{print $1}' "$tmp" | sort | uniq -c | sort -nr | head -n "$TOP_N"

    echo -e "\nTop User-Agents:"
    awk -F'"' '{print $6}' "$tmp" | sort | uniq -c | sort -nr | head -n "$TOP_N"

    rm -f "$tmp"
}

case "$LOG_KIND" in
    frontend) slice_file "FRONTEND" "$NGINX_STATUS_LOG" ;;
    backend)  slice_file "BACKEND (PHP)" "$ACCESS_LOG" ;;
    both)
        slice_file "FRONTEND" "$NGINX_STATUS_LOG"
        slice_file "BACKEND (PHP)" "$ACCESS_LOG"
        ;;
    *) echo "Invalid --log (use frontend|backend|both)" >&2; exit 1 ;;
esac
