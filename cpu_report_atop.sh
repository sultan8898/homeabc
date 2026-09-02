#!/bin/bash
# =============================================================================
# Cloudways detailed CPU + memory report from atop logs (run ON the server)
#
# One-liner:
#   curl -fsSL .../cpu_report_atop.sh | bash -s -- \
#     --email 'you@example.com' --api-key 'KEY' --days 30 --output report.txt
#
# Options:
#   --email        Cloudways email (lists all server IPs at end of report)
#   --api-key      Cloudways API key
#   --days N       Lookback window in days (default: 30)
#   --output FILE  Save report to FILE
#   --csv          Single summary row (for merging multiple servers)
#   --brief        Short summary only (no per-day table)
#   --no-server-list  Skip account server IP list
# =============================================================================

set -euo pipefail

ATOP_DIR="/var/log/atop"
API_V2="https://api.cloudways.com/api/v2"
DAYS=30
OUTPUT=""
CSV=0
BRIEF=0
SHOW_SERVER_LIST=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email) CW_EMAIL="$2"; shift 2 ;;
        --api-key) CW_API_KEY="$2"; shift 2 ;;
        --days) DAYS="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --csv) CSV=1; shift ;;
        --brief) BRIEF=1; shift ;;
        --no-server-list) SHOW_SERVER_LIST=0; shift ;;
        --verbose) ;;  # legacy alias, detailed is now default
        -h|--help)
            sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v atop >/dev/null 2>&1 || { echo "atop is required." >&2; exit 1; }
[[ -d "$ATOP_DIR" ]] || { echo "Missing $ATOP_DIR — run on a Cloudways server." >&2; exit 1; }

detect_server_id() {
    local h
    h=$(hostname -s 2>/dev/null || hostname -f 2>/dev/null || hostname)
    [[ "$h" =~ ^([0-9]+)$ ]] && { echo "${BASH_REMATCH[1]}"; return 0; }
    [[ "$h" =~ ^([0-9]+)\.cloudwaysapps\.com$ ]] && { echo "${BASH_REMATCH[1]}"; return 0; }
    if [[ -d /home/master/applications ]]; then
        h=$(ls /home/master/applications 2>/dev/null | head -n1 | grep -oE '^[0-9]+' || true)
        [[ -n "$h" ]] && { echo "$h"; return 0; }
    fi
    echo "unknown"
}

SERVER_ID=$(detect_server_id)
HOST_LABEL=$(hostname -f 2>/dev/null || hostname -s 2>/dev/null || echo "server-${SERVER_ID}")
CUTOFF=$(date -u -d "${DAYS} days ago" +%Y%m%d 2>/dev/null || date -u -v-"${DAYS}"d +%Y%m%d)
REPORT_DATE=$(date -u '+%Y-%m-%d %H:%M UTC')

emit() {
    if [[ -n "$OUTPUT" ]]; then
        printf '%s\n' "$1" >> "$OUTPUT"
    fi
    printf '%s\n' "$1"
}

api_token() {
    local body http_code
    body=$(curl -sS --max-time 30 -w $'\n__HTTP_CODE__:%{http_code}' -X POST "${API_V2}/oauth/access_token" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${CW_EMAIL}\",\"api_key\":\"${CW_API_KEY}\"}")
    http_code="${body##*$'\n__HTTP_CODE__:'}"
    body="${body%$'\n__HTTP_CODE__:'*}"
    [[ "$http_code" == "200" ]] || return 1
    echo "$body" | jq -r '.access_token // empty'
}

emit_all_servers() {
    local token json
    [[ "$SHOW_SERVER_LIST" -eq 1 ]] || return 0
    [[ -n "${CW_EMAIL:-}" && -n "${CW_API_KEY:-}" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    token=$(api_token) || {
        emit ""
        emit "ALL SERVERS (API list unavailable — check CW_EMAIL / CW_API_KEY)"
        return 0
    }

    json=$(curl -fsS --max-time 60 -H "Authorization: Bearer ${token}" \
        -H "Accept: application/json" "${API_V2}/server") || return 0

    emit ""
    emit "ALL SERVERS IN ACCOUNT (copy SSH command for the next server)"
    emit "================================================================"
    emit "$(printf '%-4s %-10s %-28s %-16s %-8s %-6s  %s' "#" "ID" "Label" "Public IP" "Cloud" "Region" "SSH")"
    emit "$(printf '%.0s-' {1..100})"

    local n=0
    while IFS=$'\t' read -r sid label ip cloud region; do
        [[ -z "$sid" ]] && continue
        n=$((n + 1))
        local mark="" ssh_line="ssh master@${ip}"
        [[ "$sid" == "$SERVER_ID" ]] && mark="*"
        emit "$(printf '%-4s %-10s %-28s %-16s %-8s %-6s  %s' "$mark" "$sid" "$label" "$ip" "$cloud" "$region" "$ssh_line")"
    done < <(echo "$json" | jq -r '.servers[]? |
        [.id, (.label // "n/a"), (
            if (.public_ip? // "") != "" then .public_ip
            elif (.server_ips? | type) == "array" then (.server_ips[0] // "n/a")
            else "n/a" end),
         (.cloud // "-"), (.region // "-")] | @tsv')

    emit ""
    emit "* = this server (report above is for this one)"
    emit "Run the same curl command on each remaining server."
    emit ""
    emit "Quick copy — server IPs only:"
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && emit "  ${ip}"
    done < <(echo "$json" | jq -r '.servers[]? |
        (if (.public_ip? // "") != "" then .public_ip
         elif (.server_ips? | type) == "array" then (.server_ips[0] // empty)
         else empty end)')
}

# Per-log CPU + memory stats: CPU values to stdout; META line to stderr.
analyze_log() {
    local log="$1"
    atop -r "$log" -b 00:00 -e 23:59 2>/dev/null | awk -v logfile="$(basename "$log")" '
    BEGIN { max_cpu = 0; max_mem = 0 }
    /^ATOP -/ { date = $4; time = $5 }
    /^CPU \|/ {
        sub(/%/, "", $4); user = $4 + 0
        sub(/%/, "", $6); sys = $6 + 0
        sub(/%/, "", $8); idle = $8 + 0
        usage = user + sys
        cpu_n++; cpu_sum += usage; idle_sum += idle
        if (usage > max_cpu) { max_cpu = usage; max_cpu_at = date " " time }
        print usage
    }
    /^MEM \|/ {
        mem_tot = mem_free = mem_cache = mem_buff = 0
        if (match($0, /tot[[:space:]]+([0-9.]+)([MG])/, m))
            mem_tot = (m[2] == "G") ? m[1] * 1024 : m[1] + 0
        if (match($0, /free[[:space:]]+([0-9.]+)([MG])/, m))
            mem_free = (m[2] == "G") ? m[1] * 1024 : m[1] + 0
        if (match($0, /cache[[:space:]]+([0-9.]+)([MG])/, m))
            mem_cache = (m[2] == "G") ? m[1] * 1024 : m[1] + 0
        if (match($0, /buff[[:space:]]+([0-9.]+)([MG])/, m))
            mem_buff = (m[2] == "G") ? m[1] * 1024 : m[1] + 0
        used = mem_tot - mem_free - mem_cache - mem_buff
        mem_n++; mem_sum += used
        if (used > max_mem) { max_mem = used; max_mem_at = date " " time }
    }
    END {
        if (cpu_n > 0) {
            printf "META log=%s samples=%d cpu_avg=%.2f cpu_max=%.2f cpu_max_at=%s mem_avg=%.2f mem_max=%.2f mem_max_at=%s\n",
                logfile, cpu_n, cpu_sum/cpu_n, max_cpu, max_cpu_at,
                (mem_n ? mem_sum/mem_n : 0), max_mem, (max_mem_at ? max_mem_at : "n/a") > "/dev/stderr"
        }
    }'
}

mapfile -t ALL_LOGS < <(ls -1 "$ATOP_DIR"/atop_*.1 2>/dev/null | sort || true)
SELECTED=()
for log in "${ALL_LOGS[@]}"; do
    base=$(basename "$log")
    [[ "$base" =~ atop_([0-9]{8})\.1$ ]] || continue
    [[ "${BASH_REMATCH[1]}" -ge "$CUTOFF" ]] && SELECTED+=("$log")
done

if [[ ${#SELECTED[@]} -eq 0 ]]; then
    echo "No atop logs in the last ${DAYS} day(s) under ${ATOP_DIR}." >&2
    exit 1
fi

FIRST_DAY=$(basename "${SELECTED[0]}" | sed -E 's/atop_([0-9]{8})\.1/\1/')
LAST_DAY=$(basename "${SELECTED[-1]}" | sed -E 's/atop_([0-9]{8})\.1/\1/')

TMP_CPU=$(mktemp)
TMP_META=$(mktemp)
trap 'rm -f "$TMP_CPU" "$TMP_META"' EXIT

for log in "${SELECTED[@]}"; do
    analyze_log "$log" >> "$TMP_CPU" 2>> "$TMP_META"
done

samples=$(wc -l < "$TMP_CPU" | tr -d ' ')
if [[ "$samples" -eq 0 ]]; then
    echo "No CPU samples found in atop logs." >&2
    exit 1
fi

cpu_min=$(awk 'BEGIN{min=1e9} {if($1<min)min=$1} END{printf "%.2f", min}' "$TMP_CPU")
cpu_max=$(awk 'BEGIN{max=0} {if($1>max)max=$1} END{printf "%.2f", max}' "$TMP_CPU")
cpu_avg=$(awk '{sum+=$1} END{printf "%.2f", sum/NR}' "$TMP_CPU")
cpu_med=$(sort -n "$TMP_CPU" | awk -v n="$samples" 'BEGIN{m=int((n+1)/2); if(m<1)m=1} NR==m{printf "%.2f", $1; exit}')
cpu_p95=$(sort -n "$TMP_CPU" | awk -v n="$samples" 'BEGIN{i=int(0.95*n); if(i<1)i=1} NR==i{printf "%.2f", $1; exit}')
cpu_p99=$(sort -n "$TMP_CPU" | awk -v n="$samples" 'BEGIN{i=int(0.99*n); if(i<1)i=1} NR==i{printf "%.2f", $1; exit}')

cpu_max_at=$(grep -F "cpu_max=${cpu_max}" "$TMP_META" 2>/dev/null | head -n1 \
    | sed -n 's/.*cpu_max_at=\([^ ]* [^ ]*\).*/\1/p')
[[ -z "$cpu_max_at" ]] && cpu_max_at="(see daily table)"

mem_avg=$(grep -o 'mem_avg=[0-9.]*' "$TMP_META" 2>/dev/null | cut -d= -f2 \
    | awk '{ s+=$1; n++ } END { printf "%.2f", (n ? s/n : 0) }')
mem_max=$(grep -o 'mem_max=[0-9.]*' "$TMP_META" 2>/dev/null | cut -d= -f2 | sort -n | tail -n1)
mem_max_at=$(grep -F "mem_max=${mem_max}" "$TMP_META" 2>/dev/null | head -n1 \
    | sed -n 's/.*mem_max_at=\([^ ]* [^ ]*\).*/\1/p')
[[ -z "$mem_max_at" ]] && mem_max_at="n/a"

PUBLIC_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "n/a")
LOAD_AVG=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "n/a")
CPU_CORES=$(nproc 2>/dev/null || echo "n/a")
MEM_NOW=$(free -h 2>/dev/null | awk '/^Mem:/ {print "used="$3" total="$2" avail="$7}' || echo "n/a")
UPTIME=$(uptime -p 2>/dev/null || uptime 2>/dev/null | sed 's/.*up/up/' || echo "n/a")
DISK_ROOT=$(df -h / 2>/dev/null | awk 'NR==2 {print $3" used / "$2" total ("$5" full)"}' || echo "n/a")

[[ -n "$OUTPUT" ]] && : > "$OUTPUT"

if [[ "$CSV" -eq 1 ]]; then
    emit $'server_id\thostname\tpublic_ip\tcpu_cores\tdays\tlog_files\tdate_from\tdate_to\tsamples\tcpu_min\tcpu_avg\tcpu_median\tcpu_p95\tcpu_p99\tcpu_max\tmem_avg_mb\tmem_max_mb\tsource'
    emit "${SERVER_ID}\t${HOST_LABEL}\t${PUBLIC_IP}\t${CPU_CORES}\t${DAYS}\t${#SELECTED[@]}\t${FIRST_DAY}\t${LAST_DAY}\t${samples}\t${cpu_min}\t${cpu_avg}\t${cpu_med}\t${cpu_p95}\t${cpu_p99}\t${cpu_max}\t${mem_avg}\t${mem_max}\tatop"
    exit 0
fi

emit "================================================================================"
emit "CLOUDWAYS SERVER RESOURCE REPORT (ATOP)"
emit "================================================================================"
emit ""
emit "SERVER INFO"
emit "---------"
emit "Generated     : ${REPORT_DATE}"
emit "Server ID     : ${SERVER_ID}"
emit "Hostname      : ${HOST_LABEL}"
emit "Public IP     : ${PUBLIC_IP}"
emit "CPU cores     : ${CPU_CORES}"
emit "Uptime        : ${UPTIME}"
emit ""
emit "REPORT PERIOD"
emit "-------------"
emit "Lookback      : last ${DAYS} days"
emit "Date range    : ${FIRST_DAY} → ${LAST_DAY}"
emit "Atop log files: ${#SELECTED[@]}"
emit "Sample points : ${samples}  (~5 min intervals)"
emit "Data source   : ${ATOP_DIR}"
emit ""
emit "CPU USAGE (user + sys %)"
emit "------------------------"
emit "Minimum       : ${cpu_min}%"
emit "Average       : ${cpu_avg}%"
emit "Median        : ${cpu_med}%"
emit "P95           : ${cpu_p95}%"
emit "P99           : ${cpu_p99}%"
emit "Maximum       : ${cpu_max}%"
emit "Peak at       : ${cpu_max_at}"
emit ""
emit "MEMORY (from atop, MB)"
emit "----------------------"
emit "Average used  : ${mem_avg} MB"
emit "Maximum used  : ${mem_max} MB"
emit "Peak at       : ${mem_max_at}"
emit ""
emit "CURRENT SNAPSHOT (right now)"
emit "----------------------------"
emit "Load average  : ${LOAD_AVG}  (1m 5m 15m)"
emit "Memory        : ${MEM_NOW}"
emit "Disk /        : ${DISK_ROOT}"
emit ""

if [[ "$BRIEF" -eq 0 ]]; then
    emit "DAILY BREAKDOWN"
    emit "---------------"
    emit "$(printf '%-12s %8s %8s %8s %10s %10s %22s' "Date" "Samples" "CPU-Avg" "CPU-Max" "Mem-Avg" "Mem-Max" "CPU peak time")"
    emit "$(printf '%.0s-' {1..88})"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        log=$(echo "$line" | sed -n 's/.*log=\([^ ]*\).*/\1/p')
        day=$(echo "$log" | sed -E 's/atop_([0-9]{8})\.1/\1/')
        s=$(echo "$line" | sed -n 's/.*samples=\([^ ]*\).*/\1/p')
        ca=$(echo "$line" | sed -n 's/.*cpu_avg=\([^ ]*\).*/\1/p')
        cm=$(echo "$line" | sed -n 's/.*cpu_max=\([^ ]*\).*/\1/p')
        ma=$(echo "$line" | sed -n 's/.*mem_avg=\([^ ]*\).*/\1/p')
        mm=$(echo "$line" | sed -n 's/.*mem_max=\([^ ]*\).*/\1/p')
        at=$(echo "$line" | sed -n 's/.*cpu_max_at=\([^ ]* [^ ]*\).*/\1/p')
        emit "$(printf '%-12s %8s %8s %8s %10s %10s %22s' "$day" "$s" "$ca" "$cm" "$ma" "$mm" "$at")"
    done < "$TMP_META"
    emit ""
fi

emit "================================================================================"
emit "Notes: CPU% = user+sys from atop. Safe to share with customers."
emit "================================================================================"

emit_all_servers
