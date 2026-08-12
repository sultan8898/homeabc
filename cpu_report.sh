#!/bin/bash
# =============================================================================
# Cloudways CPU usage report — all servers, configurable lookback (default 30d)
#
# Pulls historical CPU time-series from the Cloudways monitoring API and prints
# a customer-ready summary (avg / max / p95) per server.
#
# Requirements: curl, jq
#
# Usage (any machine with curl + jq):
#   export CW_EMAIL='you@example.com'
#   export CW_API_KEY='your-api-key'
#   ./cpu_report.sh
#
# One-liner from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/sultan8898/homeabc/main/cpu_report.sh | bash -s -- \
#     --email 'you@example.com' --api-key 'your-api-key' --days 30
#
# Options:
#   --email        Cloudways account email (or CW_EMAIL)
#   --api-key      Cloudways API key (or CW_API_KEY)
#   --days N       Lookback window in days (default: 30)
#   --duration V   Override duration token from /monitor_durations (advanced)
#   --target T     Monitor target (default: cpu)
#   --timezone TZ  Timezone for graph (default: UTC)
#   --csv          Tab-separated output (good for spreadsheets)
#   --output FILE  Save report to FILE (stdout still printed unless --quiet)
#   --quiet        Only write to --output file, not stdout
#   --sleep S      Seconds between per-server API calls (default: 1)
#   --server-id ID Only report one server (repeatable)
# =============================================================================

set -euo pipefail

API_V1="https://api.cloudways.com/api/v1"
API_V2="https://api.cloudways.com/api/v2"
DAYS=30
DURATION=""
TARGET="cpu"
TIMEZONE="UTC"
CSV=0
OUTPUT=""
QUIET=0
SLEEP_BETWEEN=1
declare -a ONLY_SERVER_IDS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email) CW_EMAIL="$2"; shift 2 ;;
        --api-key) CW_API_KEY="$2"; shift 2 ;;
        --days) DAYS="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --timezone) TIMEZONE="$2"; shift 2 ;;
        --csv) CSV=1; shift ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        --sleep) SLEEP_BETWEEN="$2"; shift 2 ;;
        --server-id) ONLY_SERVER_IDS+=("$2"); shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }

[[ -n "${CW_EMAIL:-}" && -n "${CW_API_KEY:-}" ]] || {
    echo "Set CW_EMAIL and CW_API_KEY (export) or pass --email and --api-key." >&2
    exit 1
}

api_token() {
    local body http_code
    body=$(curl -sS --max-time 30 -w $'\n__HTTP_CODE__:%{http_code}' -X POST "${API_V2}/oauth/access_token" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${CW_EMAIL}\",\"api_key\":\"${CW_API_KEY}\"}")
    http_code="${body##*$'\n__HTTP_CODE__:'}"
    body="${body%$'\n__HTTP_CODE__:'*}"

    if [[ "$http_code" != "200" ]]; then
        echo "Cloudways auth failed (HTTP ${http_code})." >&2
        err=$(echo "$body" | jq -r '.error_description // .error // .message // empty' 2>/dev/null || true)
        if [[ -n "$err" ]]; then
            echo "$err" >&2
        else
            echo "$body" >&2
        fi
        echo "Check CW_EMAIL / CW_API_KEY in Cloudways: Account → API Credentials." >&2
        return 1
    fi

    echo "$body" | jq -r '.access_token // empty'
}

api_get() {
    local url="$1"
    curl -fsS --max-time 90 -H "Authorization: Bearer ${TOKEN}" \
        -H "Accept: application/json" "$url"
}

pick_duration() {
    local json="$1"
    local picked

    # Try common response shapes and match requested day count.
    picked=$(echo "$json" | jq -r --argjson days "$DAYS" '
        def rows:
            if type == "array" then .
            elif (.durations? | type) == "array" then .durations
            elif (.duration? | type) == "array" then .duration
            elif (.data? | type) == "array" then .data
            else [] end;
        rows
        | map(select(type == "object"))
        | map(select(
            ((.days? // .day? // .value? // .id? // .key? // "") | tostring)
            | test("^" + ($days|tostring) + "$")
            or test("(?i)" + ($days|tostring) + "\\s*day")
            or test("(?i)" + ($days|tostring) + "d")
        ))
        | .[0]
        | (.value? // .id? // .key? // .duration? // empty)
    ' 2>/dev/null || true)

    if [[ -n "$picked" && "$picked" != "null" ]]; then
        echo "$picked"
        return 0
    fi

    picked=$(echo "$json" | jq -r --argjson days "$DAYS" '
        def rows:
            if type == "array" then .
            elif (.durations? | type) == "array" then .durations
            elif (.duration? | type) == "array" then .duration
            elif (.data? | type) == "array" then .data
            else [] end;
        rows
        | map(select(type == "object"))
        | sort_by(-((.days? // .day? // 0) | tonumber? // 0))
        | .[]
        | select(((.days? // .day? // 0) | tonumber? // 0) <= $days)
        | (.value? // .id? // .key? // .duration?)
        ' 2>/dev/null | head -n 1 || true)

    if [[ -n "$picked" && "$picked" != "null" ]]; then
        echo "$picked"
        return 0
    fi

    # Last resort: literal patterns Cloudways has used in the past.
    case "$DAYS" in
        1) echo "1d" ;;
        7) echo "7d" ;;
        30) echo "30d" ;;
        *) echo "${DAYS}d" ;;
    esac
}

extract_cpu_values() {
    # Accept several historical response shapes and return one number per line.
    jq -r '
        def nums:
            ..
            | select(type == "number")
            | select(. >= 0 and . <= 100);
        def series:
            if (.content? | type) == "array" then
                .content[]
                | if (.datapoint? | type) == "array" then .datapoint[]
                  elif (.datapoints? | type) == "array" then .datapoints[]
                  elif (.data? | type) == "array" then .data[]
                  else empty end
            elif (.datapoints? | type) == "array" then .datapoints[]
            elif (.data? | type) == "array" then .data[]
            elif (.graph? | type) == "array" then .graph[]
            elif (.usage? | type) == "array" then .usage[]
            else empty end;
        [
            (series
             | if type == "array" then
                   if length >= 2 and (.[1] | type) == "number" then .[1]
                   elif length >= 1 and (.[0] | type) == "number" then .[0]
                   else empty end
               elif type == "number" then .
               else empty end),
            (nums)
        ]
        | flatten
        | map(select(type == "number"))
        | unique
        | .[]
    ' 2>/dev/null
}

stats_from_values() {
    local values="$1"
    local count avg max p95

    count=$(echo "$values" | grep -c . || true)
    if [[ "$count" -eq 0 ]]; then
        echo "0,,,,no_data"
        return 0
    fi

    read -r avg max p95 < <(
        echo "$values" | awk '
            { v[NR] = $1 + 0; sum += $1; if ($1 > max || NR == 1) max = $1 }
            END {
                n = NR
                asort(v)
                idx = int(0.95 * n)
                if (idx < 1) idx = 1
                if (idx > n) idx = n
                printf "%.2f %.2f %.2f\n", sum / n, max, v[idx]
            }
        '
    )
    echo "${count},${avg},${max},${p95},ok"
}

emit() {
    if [[ -n "$OUTPUT" ]]; then
        printf '%s\n' "$1" >> "$OUTPUT"
    fi
    if [[ "$QUIET" -eq 0 ]]; then
        printf '%s\n' "$1"
    fi
}

TOKEN=$(api_token) || exit 1
[[ -n "$TOKEN" ]] || { echo "Failed to obtain API token (empty response)." >&2; exit 1; }

if [[ -z "$DURATION" ]]; then
    DUR_JSON=$(api_get "${API_V1}/monitor_durations" || api_get "${API_V2}/monitoring/durations")
    DURATION=$(pick_duration "$DUR_JSON")
fi

SERVERS_JSON=$(api_get "${API_V2}/server")
SERVER_ROWS=$(echo "$SERVERS_JSON" | jq -r '.servers[]? | [.id, .label, .status, .cloud, .region] | @tsv')

if [[ ${#ONLY_SERVER_IDS[@]} -gt 0 ]]; then
    WANT_IDS=$(printf '%s\n' "${ONLY_SERVER_IDS[@]}" | jq -R . | jq -s .)
    SERVER_ROWS=$(echo "$SERVER_ROWS" | jq -R -s --argjson want "$WANT_IDS" '
        split("\n")
        | map(select(length > 0))
        | map(split("\t"))
        | map(select(.[0] as $id | $want | index($id)))
        | map(join("\t"))
        | .[]
    ')
fi

REPORT_DATE=$(date -u '+%Y-%m-%d %H:%M UTC')
ACCOUNT_EMAIL_MASKED="${CW_EMAIL/@*/@***}"

if [[ -n "$OUTPUT" ]]; then
    : > "$OUTPUT"
fi

if [[ "$CSV" -eq 1 ]]; then
  emit $'server_id\tserver_label\tstatus\tcloud\tregion\tsamples\tavg_cpu_pct\tmax_cpu_pct\tp95_cpu_pct\tresult'
else
  emit "================================================================"
  emit "CLOUDWAYS CPU USAGE REPORT"
  emit "Generated : ${REPORT_DATE}"
  emit "Account   : ${ACCOUNT_EMAIL_MASKED}"
  emit "Period    : last ${DAYS} day(s)  (duration=${DURATION}, target=${TARGET})"
  emit "================================================================"
  emit ""
  emit "$(printf '%-8s %-28s %-10s %-8s %-6s %7s %7s %7s %7s' \
    "ID" "Server" "Status" "Cloud" "Region" "Samples" "Avg%" "Max%" "P95%")"
  emit "$(printf '%.0s-' {1..100})"
fi

TOTAL=0
OK=0
FAILED=0

while IFS=$'\t' read -r sid label status cloud region; do
    [[ -z "$sid" ]] && continue
    TOTAL=$((TOTAL + 1))

    DETAIL_URL="${API_V1}/server/monitor/detail?server_id=${sid}&target=${TARGET}&duration=${DURATION}&timezone=${TIMEZONE}&output_format=json"
    DETAIL_JSON=""
    if DETAIL_JSON=$(api_get "$DETAIL_URL" 2>/dev/null); then
        :
    else
        DETAIL_URL="${API_V2}/servers/${sid}/monitoring/graph?metric=${TARGET}&duration=${DURATION}&timezone=${TIMEZONE}"
        DETAIL_JSON=$(api_get "$DETAIL_URL" 2>/dev/null || echo '{}')
    fi

    VALUES=$(echo "$DETAIL_JSON" | extract_cpu_values || true)
    IFS=',' read -r samples avg max p95 result <<< "$(stats_from_values "$VALUES")"

    if [[ "$result" == "ok" ]]; then
        OK=$((OK + 1))
    else
        FAILED=$((FAILED + 1))
        result="no_data"
    fi

    label=${label:-"(unnamed)"}
    status=${status:-"-"}
    cloud=${cloud:-"-"}
    region=${region:-"-"}

    if [[ "$CSV" -eq 1 ]]; then
        emit "${sid}\t${label}\t${status}\t${cloud}\t${region}\t${samples}\t${avg}\t${max}\t${p95}\t${result}"
    else
        emit "$(printf '%-8s %-28s %-10s %-8s %-6s %7s %7s %7s %7s %s' \
            "$sid" "$label" "$status" "$cloud" "$region" "$samples" "$avg" "$max" "$p95" "$result")"
    fi

    sleep "$SLEEP_BETWEEN"
done <<< "$SERVER_ROWS"

if [[ "$CSV" -eq 0 ]]; then
  emit ""
  emit "----------------------------------------------------------------"
  emit "Summary: ${TOTAL} server(s) | ${OK} with data | ${FAILED} without data"
  emit "----------------------------------------------------------------"
  emit ""
  emit "Notes:"
  emit "- Percentages are computed from Cloudways monitoring graph datapoints."
  emit "- Share this file directly with the customer, or use --csv for Excel/Sheets."
  emit "- Re-run anytime; credentials are not stored by this script."
fi
