#!/bin/bash
# =============================================================================
# Cloudways CPU report — ALL servers from ONE machine (SSH + atop)
#
# The Cloudways monitoring API often returns no_data for historical CPU.
# This script uses the API only to list servers, then SSHs into each one
# and runs atop-based CPU stats remotely.
#
# Requirements:
#   - curl, jq, ssh
#   - CW_EMAIL + CW_API_KEY (to list servers and get IPs)
#   - SSH key allowed on every server (master@<server-ip>)
#   - Your IP whitelisted for SSH on each server
#
# Usage:
#   export CW_EMAIL='you@example.com'
#   export CW_API_KEY='your-api-key'
#   export SSH_USER='master'          # default: master
#   export SSH_KEY='~/.ssh/id_rsa'   # optional
#
#   ./cpu_report_all.sh --days 30 --output cpu_report_30d.txt
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/sultan8898/homeabc/cursor/cpu-usage-report-2439/cpu_report_all.sh | bash -s -- \
#     --email 'you@example.com' --api-key 'KEY' --days 30 --output cpu_report_30d.txt
# =============================================================================

set -euo pipefail

API_V2="https://api.cloudways.com/api/v2"
ATOP_SCRIPT_URL="https://raw.githubusercontent.com/sultan8898/homeabc/cursor/cpu-usage-report-2439/cpu_report_atop.sh"
DAYS=30
OUTPUT=""
CSV=0
QUIET=0
SSH_USER="${SSH_USER:-master}"
SSH_KEY="${SSH_KEY:-}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new}"
SLEEP_BETWEEN=2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email) CW_EMAIL="$2"; shift 2 ;;
        --api-key) CW_API_KEY="$2"; shift 2 ;;
        --days) DAYS="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --csv) CSV=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --sleep) SLEEP_BETWEEN="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "ssh is required." >&2; exit 1; }

[[ -n "${CW_EMAIL:-}" && -n "${CW_API_KEY:-}" ]] || {
    echo "Set CW_EMAIL and CW_API_KEY or pass --email and --api-key." >&2
    exit 1
}

api_token() {
    local body http_code
    body=$(curl -sS --max-time 30 -w $'\n__HTTP_CODE__:%{http_code}' -X POST "${API_V2}/oauth/access_token" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${CW_EMAIL}\",\"api_key\":\"${CW_API_KEY}\"}")
    http_code="${body##*$'\n__HTTP_CODE__:'}"
    body="${body%$'\n__HTTP_CODE__:'*}"
    [[ "$http_code" == "200" ]] || { echo "Auth failed (HTTP ${http_code})." >&2; return 1; }
    echo "$body" | jq -r '.access_token // empty'
}

emit() {
    if [[ -n "$OUTPUT" ]]; then
        printf '%s\n' "$1" >> "$OUTPUT"
    fi
    [[ "$QUIET" -eq 0 ]] && printf '%s\n' "$1"
}

local_server_id() {
    local h
    h=$(hostname -s 2>/dev/null || hostname)
    [[ "$h" =~ ^[0-9]+$ ]] && echo "$h" && return 0
    [[ "$h" =~ ^([0-9]+)\.cloudwaysapps\.com$ ]] && echo "${BASH_REMATCH[1]}" && return 0
    echo ""
}

run_local_atop_csv() {
    if [[ -x "./cpu_report_atop.sh" ]]; then
        ./cpu_report_atop.sh --days "$DAYS" --csv 2>/dev/null | tail -n1
        return 0
    fi
    curl -fsSL "$ATOP_SCRIPT_URL" | bash -s -- --days "$DAYS" --csv 2>/dev/null | tail -n1
}

run_remote_atop_csv() {
    local ip="$1"
    local ssh_cmd=(ssh $SSH_OPTS)
    [[ -n "$SSH_KEY" ]] && ssh_cmd+=(-i "$SSH_KEY")
    ssh_cmd+=("${SSH_USER}@${ip}")
    "${ssh_cmd[@]}" "curl -fsSL '$ATOP_SCRIPT_URL' | bash -s -- --days $DAYS --csv" 2>/dev/null | tail -n1
}

TOKEN=$(api_token) || exit 1
SERVERS_JSON=$(curl -fsS --max-time 60 -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" "${API_V2}/server")

LOCAL_SID=$(local_server_id)
REPORT_DATE=$(date -u '+%Y-%m-%d %H:%M UTC')
ACCOUNT_EMAIL_MASKED="${CW_EMAIL/@*/@***}"

[[ -n "$OUTPUT" ]] && : > "$OUTPUT"

if [[ "$CSV" -eq 1 ]]; then
    emit $'server_id\tserver_label\tstatus\tcloud\tregion\tsamples\tavg_cpu_pct\tmax_cpu_pct\tp95_cpu_pct\tresult'
else
    emit "================================================================"
    emit "CLOUDWAYS CPU USAGE REPORT (ALL SERVERS)"
    emit "Generated : ${REPORT_DATE}"
    emit "Account   : ${ACCOUNT_EMAIL_MASKED}"
    emit "Period    : last ${DAYS} day(s) via atop (SSH to each server)"
    emit "SSH user  : ${SSH_USER}"
    emit "================================================================"
    emit ""
    emit "$(printf '%-8s %-28s %-10s %-8s %-6s %7s %7s %7s %7s' \
        "ID" "Server" "Status" "Cloud" "Region" "Samples" "Avg%" "Max%" "P95%")"
    emit "$(printf '%.0s-' {1..100})"
fi

TOTAL=0
OK=0
FAILED=0

while IFS=$'\t' read -r sid label status cloud region ip; do
    [[ -z "$sid" ]] && continue
    TOTAL=$((TOTAL + 1))

    result="no_data"
    samples="" avg="" max="" p95=""

    if [[ -n "$LOCAL_SID" && "$sid" == "$LOCAL_SID" ]]; then
        row=$(run_local_atop_csv || true)
        source_note="atop-local"
    elif [[ -n "$ip" && "$ip" != "null" ]]; then
        row=$(run_remote_atop_csv "$ip" || true)
        source_note="atop-ssh"
    else
        row=""
        source_note="no_ip"
    fi

    if [[ -n "$row" ]]; then
        IFS=$'\t' read -r rid rlabel days logs samples avg max p95 rsource <<< "$row"
        if [[ -n "$samples" && "$samples" != "0" ]]; then
            result="$source_note"
            OK=$((OK + 1))
        else
            FAILED=$((FAILED + 1))
        fi
    else
        FAILED=$((FAILED + 1))
    fi

    label=${label:-"(unnamed)"}
    if [[ "$CSV" -eq 1 ]]; then
        emit "${sid}\t${label}\t${status}\t${cloud}\t${region}\t${samples:-0}\t${avg:-}\t${max:-}\t${p95:-}\t${result}"
    else
        emit "$(printf '%-8s %-28s %-10s %-8s %-6s %7s %7s %7s %7s %s' \
            "$sid" "$label" "$status" "$cloud" "$region" "${samples:-0}" "${avg:-}" "${max:-}" "${p95:-}" "$result")"
    fi

    sleep "$SLEEP_BETWEEN"
done < <(echo "$SERVERS_JSON" | jq -r '.servers[]? |
    [.id, .label, .status, .cloud, .region, (.public_ip // .server_ips[0] // "")] | @tsv')

if [[ "$CSV" -eq 0 ]]; then
    emit ""
    emit "----------------------------------------------------------------"
    emit "Summary: ${TOTAL} server(s) | ${OK} with data | ${FAILED} without data"
    emit "----------------------------------------------------------------"
    emit ""
    emit "Notes:"
    emit "- Run from one machine with SSH access to all servers (master@IP + key whitelisted)."
    emit "- Cloudways API does not expose historical CPU; atop on each server is the source."
    emit "- If SSH fails, whitelist your IP under Server → Master Credentials → SSH/SFTP."
fi
