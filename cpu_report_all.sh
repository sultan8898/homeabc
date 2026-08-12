#!/bin/bash
# =============================================================================
# Cloudways CPU report — ALL servers from ONE machine (SSH + atop)
#
# Uses Cloudways API to list servers, then collects atop CPU stats from each
# server via SSH (or locally when run on that server).
#
# Requirements: curl, jq, ssh, atop on target servers
#   - CW_EMAIL + CW_API_KEY
#   - SSH key + IP whitelisted on each server
#
# Usage:
#   ./cpu_report_all.sh --email 'you@example.com' --api-key 'KEY' --days 30
#
# If master@IP fails, try:
#   --ssh-user root --ssh-host server_id
#   (uses root@1235009 style when host is the numeric server ID)
#
# Debug SSH/connection issues:
#   ./cpu_report_all.sh ... --debug
# =============================================================================

set -euo pipefail

API_V2="https://api.cloudways.com/api/v2"
DAYS=30
OUTPUT=""
CSV=0
QUIET=0
DEBUG=0
SSH_USER="${SSH_USER:-master}"
SSH_HOST_MODE="${SSH_HOST_MODE:-ip}"   # ip | server_id | both
SSH_KEY="${SSH_KEY:-}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=25 -o StrictHostKeyChecking=accept-new)
SLEEP_BETWEEN=2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email) CW_EMAIL="$2"; shift 2 ;;
        --api-key) CW_API_KEY="$2"; shift 2 ;;
        --days) DAYS="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --csv) CSV=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --debug) DEBUG=1; shift ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --ssh-host) SSH_HOST_MODE="$2"; shift 2 ;;
        --sleep) SLEEP_BETWEEN="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
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

dbg() { [[ "$DEBUG" -eq 1 ]] && echo "# $*" >&2; }

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
    h=$(hostname -s 2>/dev/null || hostname -f 2>/dev/null || hostname)
    [[ "$h" =~ ^[0-9]+$ ]] && echo "$h" && return 0
    [[ "$h" =~ ^([0-9]+)\.cloudwaysapps\.com$ ]] && echo "${BASH_REMATCH[1]}" && return 0
    echo ""
}

# Inline atop stats — runs locally or via "bash -s" over SSH (no GitHub needed).
atop_stats_script() {
    cat <<'ATOP_EOF'
set -euo pipefail
DAYS="${1:-30}"
ATOP_DIR="/var/log/atop"
command -v atop >/dev/null 2>&1 || { echo "ERR:no_atop" >&2; exit 3; }
[[ -d "$ATOP_DIR" ]] || { echo "ERR:no_atop_dir" >&2; exit 3; }
CUTOFF=$(date -u -d "${DAYS} days ago" +%Y%m%d 2>/dev/null || date -u -v-"${DAYS}"d +%Y%m%d)
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
for log in "$ATOP_DIR"/atop_*.1; do
  [[ -f "$log" ]] || continue
  base=$(basename "$log")
  [[ "$base" =~ atop_([0-9]{8})\.1$ ]] || continue
  [[ "${BASH_REMATCH[1]}" -ge "$CUTOFF" ]] || continue
  atop -r "$log" -b 00:00 -e 23:59 2>/dev/null | awk '
    /^CPU \|/ {
      sub(/%/, "", $4); user = $4 + 0
      sub(/%/, "", $6); sys = $6 + 0
      print user + sys
    }' >> "$TMP"
done
[[ -s "$TMP" ]] || { echo "ERR:no_samples" >&2; exit 4; }
awk -v days="$DAYS" '
  { v[NR] = $1 + 0; sum += $1; if ($1 > max || NR == 1) max = $1 }
  END {
    n = NR; asort(v)
    idx = int(0.95 * n); if (idx < 1) idx = 1; if (idx > n) idx = n
  printf "samples=%d avg=%.2f max=%.2f p95=%.2f logs=%d\n", n, sum/n, max, v[idx], NR
  }' "$TMP"
ATOP_EOF
}

run_atop_local() {
    bash -s "$DAYS" <<< "$(atop_stats_script)" 2>&1
}

run_atop_ssh() {
    local target="$1"
    local ssh_cmd=(ssh "${SSH_OPTS[@]}")
    [[ -n "$SSH_KEY" ]] && ssh_cmd+=(-i "$SSH_KEY")
    ssh_cmd+=("$target" "bash -s $DAYS")
    "${ssh_cmd[@]}" 2>&1 <<< "$(atop_stats_script)"
}

ssh_targets_for() {
    local sid="$1" ip="$2"
    case "$SSH_HOST_MODE" in
        ip)
            [[ -n "$ip" && "$ip" != "null" ]] && echo "${SSH_USER}@${ip}"
            ;;
        server_id)
            echo "${SSH_USER}@${sid}"
            ;;
        both)
            [[ -n "$ip" && "$ip" != "null" ]] && echo "${SSH_USER}@${ip}"
            echo "${SSH_USER}@${sid}"
            ;;
        *) echo "${SSH_USER}@${ip}" ;;
    esac
}

collect_server_stats() {
    local sid="$1" ip="$2"
    local out target err

    if [[ -n "$LOCAL_SID" && "$sid" == "$LOCAL_SID" ]]; then
        dbg "server $sid: trying local atop"
        if out=$(run_atop_local); then
            echo "atop-local|$out"
            return 0
        fi
        dbg "server $sid: local atop failed: $out"
    fi

    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        dbg "server $sid: trying ssh $target"
        err=$(mktemp)
        if out=$(run_atop_ssh "$target" 2>"$err"); then
            rm -f "$err"
            echo "atop-ssh|$out"
            return 0
        fi
        dbg "server $sid: ssh $target failed: $(tr '\n' ' ' < "$err")"
        rm -f "$err"
    done < <(ssh_targets_for "$sid" "$ip")

    echo "no_data|"
    return 1
}

parse_atop_output() {
    local source_line="$1"
    local source="${source_line%%|*}"
    local body="${source_line#*|}"
    local samples avg max p95

    if [[ "$body" =~ samples=([0-9]+) ]]; then
        samples="${BASH_REMATCH[1]}"
    fi
    if [[ "$body" =~ avg=([0-9.]+) ]]; then
        avg="${BASH_REMATCH[1]}"
    fi
    if [[ "$body" =~ max=([0-9.]+) ]]; then
        max="${BASH_REMATCH[1]}"
    fi
    if [[ "$body" =~ p95=([0-9.]+) ]]; then
        p95="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$samples" && "$samples" != "0" ]]; then
        echo "${samples}|${avg}|${max}|${p95}|${source}"
        return 0
    fi
    echo "0||||no_data"
}

TOKEN=$(api_token) || exit 1
SERVERS_JSON=$(curl -fsS --max-time 60 -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json" "${API_V2}/server")

LOCAL_SID=$(local_server_id)
dbg "local_server_id=${LOCAL_SID:-none}"

if [[ "$DEBUG" -eq 1 ]]; then
    echo "# servers from API:" >&2
    echo "$SERVERS_JSON" | jq -r '.servers[]? | "\(.id)\t\(.label)\t\(.public_ip // .server_ips[0] // "NO_IP")"' >&2
fi

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
    emit "SSH user  : ${SSH_USER}  (host mode: ${SSH_HOST_MODE})"
    [[ -n "$LOCAL_SID" ]] && emit "Local srv : ${LOCAL_SID} (atop used locally when matched)"
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

    raw=$(collect_server_stats "$sid" "$ip" || true)
    IFS='|' read -r samples avg max p95 result <<< "$(parse_atop_output "$raw")"

    if [[ "$result" != "no_data" && -n "$samples" && "$samples" != "0" ]]; then
        OK=$((OK + 1))
    else
        FAILED=$((FAILED + 1))
        result="no_data"
        samples="0"
    fi

    label=${label:-"(unnamed)"}
    if [[ "$CSV" -eq 1 ]]; then
        emit "${sid}\t${label}\t${status}\t${cloud}\t${region}\t${samples}\t${avg}\t${max}\t${p95}\t${result}"
    else
        emit "$(printf '%-8s %-28s %-10s %-8s %-6s %7s %7s %7s %7s %s' \
            "$sid" "$label" "$status" "$cloud" "$region" "$samples" "${avg:-}" "${max:-}" "${p95:-}" "$result")"
    fi

    sleep "$SLEEP_BETWEEN"
done < <(echo "$SERVERS_JSON" | jq -r '.servers[]? |
    [.id, .label, .status, .cloud, .region,
     (if (.public_ip? // "") != "" then .public_ip
      elif (.server_ips? | type) == "array" then (.server_ips[0] // "")
      elif (.server_ips? | type) == "string" then .server_ips
      else "" end)] | @tsv')

if [[ "$CSV" -eq 0 ]]; then
    emit ""
    emit "----------------------------------------------------------------"
    emit "Summary: ${TOTAL} server(s) | ${OK} with data | ${FAILED} without data"
    emit "----------------------------------------------------------------"
    emit ""
    emit "Notes:"
    emit "- Re-run with --debug to see SSH targets and errors on stderr."
    emit "- If master@IP fails, try: --ssh-user root --ssh-host server_id"
    emit "- Whitelist your IP: Server → Master Credentials → SSH/SFTP."
    emit "- cpu_report.sh on one server still works for that server only (atop fallback)."
fi
