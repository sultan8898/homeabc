#!/bin/bash
# =============================================================================
# Cloudways CPU report from local atop logs (run ON the server)
#
# Use this when the Cloudways monitoring API returns no_data but atop has history.
# Matches the output style of cpu_report.sh for customer sharing.
#
# Usage (on a Cloudways server):
#   curl -fsSL https://raw.githubusercontent.com/sultan8898/homeabc/cursor/cpu-usage-report-2439/cpu_report_atop.sh | bash -s -- --days 30
#
# Options:
#   --days N       Lookback window in days (default: 30)
#   --output FILE  Save report to FILE
#   --csv          Tab-separated single-row output
#   --verbose      Show per-day breakdown (like atop.sh)
# =============================================================================

set -euo pipefail

ATOP_DIR="/var/log/atop"
DAYS=30
OUTPUT=""
CSV=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) DAYS="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --csv) CSV=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v atop >/dev/null 2>&1 || { echo "atop is required (install atop package)." >&2; exit 1; }
[[ -d "$ATOP_DIR" ]] || { echo "Missing $ATOP_DIR — run this on a Cloudways server." >&2; exit 1; }

detect_server_id() {
    local h
    h=$(hostname -s 2>/dev/null || hostname -f 2>/dev/null || hostname)
    if [[ "$h" =~ ^([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$h" =~ ^([0-9]+)\.cloudwaysapps\.com$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ -d /home/master/applications ]]; then
        id=$(ls /home/master/applications 2>/dev/null | head -n1 | grep -oE '^[0-9]+' || true)
        [[ -n "$id" ]] && echo "$id" && return 0
    fi
    echo "unknown"
}

SERVER_ID=$(detect_server_id)
CUTOFF=$(date -u -d "${DAYS} days ago" +%Y%m%d 2>/dev/null || date -u -v-"${DAYS}"d +%Y%m%d)

emit() {
    if [[ -n "$OUTPUT" ]]; then
        printf '%s\n' "$1" >> "$OUTPUT"
    fi
    printf '%s\n' "$1"
}

process_log() {
    local log="$1"
  atop -r "$log" -b 00:00 -e 23:59 2>/dev/null | awk '
  /^ATOP -/ { date = $4; time = $5 }
  /^CPU \|/ {
    sub(/%/, "", $4); user = $4 + 0
    sub(/%/, "", $6); sys = $6 + 0
    usage = user + sys
    print usage
  }'
}

mapfile -t LOGS < <(ls -1 "$ATOP_DIR"/atop_*.1 2>/dev/null | sort || true)
SELECTED=()
for log in "${LOGS[@]}"; do
    base=$(basename "$log")
  if [[ "$base" =~ atop_([0-9]{8})\.1$ ]]; then
        d="${BASH_REMATCH[1]}"
        [[ "$d" -ge "$CUTOFF" ]] && SELECTED+=("$log")
    fi
done

if [[ ${#SELECTED[@]} -eq 0 ]]; then
    echo "No atop logs found in the last ${DAYS} day(s) under ${ATOP_DIR}." >&2
    exit 1
fi

TMP_VALUES=$(mktemp)
trap 'rm -f "$TMP_VALUES"' EXIT

for log in "${SELECTED[@]}"; do
    if [[ "$VERBOSE" -eq 1 ]]; then
        echo "Processing $(basename "$log")..." >&2
        atop -r "$log" -b 00:00 -e 23:59 2>/dev/null | awk '
          BEGIN { max_usage = 0 }
          /^ATOP -/ { date = $4; time = $5 }
          /^CPU \|/ {
            sub(/%/, "", $4); user = $4 + 0
            sub(/%/, "", $6); sys = $6 + 0
            usage = user + sys
            total += usage; n++
            if (usage > max_usage) { max_usage = usage; max_date = date; max_time = time }
          }
          END {
            if (n > 0) printf " Avg CPU (user+sys): %.2f%%\n Max CPU (user+sys): %.2f%% at %s %s\n", total/n, max_usage, max_date, max_time
          }' >&2
    fi
    process_log "$log" >> "$TMP_VALUES"
done

read -r samples avg max p95 < <(
    awk '
      { v[NR] = $1 + 0; sum += $1; if ($1 > max || NR == 1) max = $1 }
      END {
        n = NR
        if (n == 0) { print "0 0 0 0"; exit }
        asort(v)
        idx = int(0.95 * n); if (idx < 1) idx = 1; if (idx > n) idx = n
        printf "%d %.2f %.2f %.2f\n", n, sum/n, max, v[idx]
      }
    ' "$TMP_VALUES"
)

REPORT_DATE=$(date -u '+%Y-%m-%d %H:%M UTC')
HOST_LABEL=$(hostname -s 2>/dev/null || echo "server-${SERVER_ID}")

if [[ -n "$OUTPUT" ]]; then
    : > "$OUTPUT"
fi

if [[ "$CSV" -eq 1 ]]; then
    emit $'server_id\thost_label\tdays\tlog_files\tsamples\tavg_cpu_pct\tmax_cpu_pct\tp95_cpu_pct\tsource'
    emit "${SERVER_ID}\t${HOST_LABEL}\t${DAYS}\t${#SELECTED[@]}\t${samples}\t${avg}\t${max}\t${p95}\tatop"
else
    emit "================================================================"
    emit "CLOUDWAYS CPU USAGE REPORT (ATOP)"
    emit "Generated : ${REPORT_DATE}"
    emit "Server ID : ${SERVER_ID}"
    emit "Hostname  : ${HOST_LABEL}"
    emit "Period    : last ${DAYS} day(s) from ${#SELECTED[@]} atop log file(s)"
    emit "================================================================"
    emit ""
    emit "Samples : ${samples}"
    emit "Avg CPU : ${avg}%  (user+sys)"
    emit "Max CPU : ${max}%"
    emit "P95 CPU : ${p95}%"
    emit ""
    emit "Source: /var/log/atop (5-minute samples aggregated)"
    emit "Re-run on each server, or use cpu_report.sh --mode atop-ssh for account-wide."
fi
