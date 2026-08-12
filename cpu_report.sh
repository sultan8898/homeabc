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
#   --debug        Print API metadata and save raw JSON per server to /tmp
#   --source api|atop-hint  Force data source notes (default: api)
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
DEBUG=0
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
        --debug) DEBUG=1; shift ;;
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

    picked=$(echo "$json" | jq -r --argjson days "$DAYS" '
        def rows:
            if type == "array" then .
            elif (.durations? | type) == "array" then .durations
            elif (.duration? | type) == "array" then .duration
            elif (.data? | type) == "array" then .data
            else [] end;
        rows
        | map(select(type == "object"))
        | map(. + {
            _label: ((.label? // .title? // .name? // .text? // "") | tostring),
            _value: ((.value? // .id? // .key? // .duration? // .code? // "") | tostring)
          })
        | map(select(
            ._label | test("(?i)" + ($days|tostring) + "\\s*day")
            or ._value | test("(?i)" + ($days|tostring) + "\\s*day")
            or ._value | test("(?i)last[_-]?" + ($days|tostring) + "[_-]?days?")
            or ._value | test("(?i)^" + ($days|tostring) + "d$")
        ))
        | .[0]._value // empty
    ' 2>/dev/null || true)

    if [[ -n "$picked" && "$picked" != "null" ]]; then
        echo "$picked"
        return 0
    fi

    # Common Cloudways duration tokens seen in the wild.
    case "$DAYS" in
        1)  echo "last_24_hours" ;;
        7)  echo "last_7_days" ;;
        30) echo "last_30_days" ;;
        *)  echo "last_${DAYS}_days" ;;
    esac
}

pick_target() {
    local json="$1"
    local picked

    picked=$(echo "$json" | jq -r '
        def rows:
            if type == "array" then .
            elif (.targets? | type) == "array" then .targets
            elif (.target? | type) == "array" then .target
            elif (.data? | type) == "array" then .data
            else [] end;
        rows
        | map(select(type == "object"))
        | map(. + {
            _label: ((.label? // .title? // .name? // .text? // "") | tostring),
            _value: ((.value? // .id? // .key? // .target? // .code? // "") | tostring)
          })
        | map(select(._label | test("(?i)cpu") or ._value | test("(?i)cpu")))
        | .[0]._value // empty
    ' 2>/dev/null || true)

    if [[ -n "$picked" && "$picked" != "null" ]]; then
        echo "$picked"
        return 0
    fi
    echo "cpu"
}

extract_cpu_values() {
    jq -r '
        def as_num:
            if type == "number" then .
            elif type == "string" then (tonumber? // empty)
            else empty end;
        def from_leaf:
            if type == "array" then
                if length >= 2 then
                    (.[1] | as_num) // (.[0] | as_num)
                else .[] | from_leaf end
            elif type == "object" then
                (.y? // .value? // .usage? // .cpu? // .percent? | as_num)
            else as_num end;
        def walk:
            if type == "array" then .[] | walk
            elif type == "object" then
                (.content?, .datapoint?, .datapoints?, .data?, .graph?, .usage?, .values?, .series?)
                | walk,
                (.series[]?.data? | walk)
            else from_leaf end;
        [walk]
        | map(select(type == "number"))
        | map(if . > 0 and . <= 1 then . * 100 else . end)
        | map(select(. >= 0 and . <= 100))
        | unique
        | .[]
    ' 2>/dev/null
}

duration_candidates() {
    local primary="$1"
    printf '%s\n' "$primary" "last_${DAYS}_days" "${DAYS}d" "${DAYS}" "2592000"
}

target_candidates() {
    local primary="$1"
    printf '%s\n' "$primary" "cpu" "CPU" "cpu_usage" "load"
}

fetch_cpu_json() {
    local sid="$1" dur target url body

    while IFS= read -r dur; do
        [[ -z "$dur" ]] && continue
        while IFS= read -r target; do
            [[ -z "$target" ]] && continue

            url="${API_V1}/server/monitor/detail?server_id=${sid}&target=${target}&duration=${dur}&timezone=${TIMEZONE}&output_format=json"
            if body=$(api_get "$url" 2>/dev/null); then
                if [[ "$(echo "$body" | extract_cpu_values | head -n1)" != "" ]]; then
                    [[ "$DEBUG" -eq 1 ]] && echo "$body" > "/tmp/cw_cpu_${sid}_${target}_${dur}.json"
                    echo "$body"
                    return 0
                fi
                [[ "$DEBUG" -eq 1 ]] && echo "$body" > "/tmp/cw_cpu_${sid}_${target}_${dur}_empty.json"
            fi

            url="${API_V1}/server/monitor/summary?server_id=${sid}&type=${target}"
            if body=$(api_get "$url" 2>/dev/null); then
                if [[ "$(echo "$body" | extract_cpu_values | head -n1)" != "" ]]; then
                    [[ "$DEBUG" -eq 1 ]] && echo "$body" > "/tmp/cw_cpu_${sid}_summary_${target}.json"
                    echo "$body"
                    return 0
                fi
            fi

            url="${API_V2}/servers/${sid}/monitoring/graph?metric=${target}&duration=${dur}&timezone=${TIMEZONE}"
            if body=$(api_get "$url" 2>/dev/null); then
                if [[ "$(echo "$body" | extract_cpu_values | head -n1)" != "" ]]; then
                    [[ "$DEBUG" -eq 1 ]] && echo "$body" > "/tmp/cw_cpu_${sid}_v2_${target}_${dur}.json"
                    echo "$body"
                    return 0
                fi
            fi
        done < <(target_candidates "$TARGET")
    done < <(duration_candidates "$DURATION")

    echo '{}'
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
    DUR_JSON=$(api_get "${API_V1}/monitor_durations" 2>/dev/null || api_get "${API_V2}/monitoring/durations")
    DURATION=$(pick_duration "$DUR_JSON")
else
    DUR_JSON='{}'
fi

TARGET_JSON=$(api_get "${API_V1}/monitor_targets" 2>/dev/null || api_get "${API_V2}/monitoring/targets" 2>/dev/null || echo '{}')
TARGET=$(pick_target "$TARGET_JSON")

if [[ "$DEBUG" -eq 1 ]]; then
    echo "# duration=${DURATION} target=${TARGET}" >&2
    echo "# monitor_durations:" >&2
    echo "$DUR_JSON" | jq . >&2 2>/dev/null || echo "$DUR_JSON" >&2
    echo "# monitor_targets:" >&2
    echo "$TARGET_JSON" | jq . >&2 2>/dev/null || echo "$TARGET_JSON" >&2
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

    DETAIL_JSON=$(fetch_cpu_json "$sid")
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
  emit "- If API shows no_data, run cpu_report_atop.sh ON each server (uses /var/log/atop)."
  emit "- Share this file directly with the customer, or use --csv for Excel/Sheets."
  emit "- Re-run with --debug to save raw API JSON under /tmp/cw_cpu_*.json"
fi
