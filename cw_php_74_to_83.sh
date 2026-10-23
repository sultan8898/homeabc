#!/usr/bin/env bash
# Upgrade listed Cloudways apps from PHP 7.4 -> 8.3 via API (full URLs below).
#
# Auth (pick one):
#   export CW_ACCESS_TOKEN='cw_...'
#   export CW_EMAIL='you@example.com' CW_API_KEY='...'
#
# Required on multi-server accounts when not inferrable from nginx:
#   export CW_SERVER_ID='123456'
#
# Usage:
#   ./cw_php_74_to_83.sh --dry-run          # resolve IDs, no POST
#   ./cw_php_74_to_83.sh                    # apply upgrades sequentially
#   ./cw_php_74_to_83.sh --sys-users-file my_apps.txt
#
# API endpoints used (all HTTPS):
#   POST https://api.cloudways.com/api/v2/oauth/access_token
#   GET  https://api.cloudways.com/api/v2/applications
#   GET  https://api.cloudways.com/api/v1/server          (fallback)
#   POST https://api.cloudways.com/api/v2/app/manage/php_version
#   POST https://api.cloudways.com/api/v1/app/manage/php_version  (fallback)
#   GET  https://api.cloudways.com/api/v2/operation/{operation_id}

set -euo pipefail

API_V2='https://api.cloudways.com/api/v2'
API_V1='https://api.cloudways.com/api/v1'
TARGET_PHP='8.3'
POLL_SEC=10
POLL_MAX=90
SLEEP_BETWEEN=8

DRY_RUN=0
SYS_USERS_FILE=''

DEFAULT_SYS_USERS=(
  anwynsdpyw csythsnghw ebecbmqchv fwujsxzzsg fzamnwmxfk jehxtbuqun keyabdgabh
  meuuxrtkkp myfwgyzjkq pvewmdecah rbrxjcmmpu rntqxteeuf spzakvfyma vnhwtnfcdk
  xtyuqmgzcq
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --sys-users-file) SYS_USERS_FILE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo 'curl is required' >&2; exit 1; }

declare -a WANT_USERS=()
if [[ -n "$SYS_USERS_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    # allow "7.4  sysuser" from pool audit output
    u="${line##*[[:space:]]}"
    WANT_USERS+=("$u")
  done < "$SYS_USERS_FILE"
else
  WANT_USERS=("${DEFAULT_SYS_USERS[@]}")
fi

api_token() {
  if [[ -n "${CW_ACCESS_TOKEN:-}" ]]; then
    printf '%s' "$CW_ACCESS_TOKEN"
    return 0
  fi
  [[ -n "${CW_EMAIL:-}" && -n "${CW_API_KEY:-}" ]] || {
    echo 'Set CW_ACCESS_TOKEN or CW_EMAIL + CW_API_KEY' >&2
    exit 1
  }
  curl -fsS --max-time 45 -X POST "${API_V2}/oauth/access_token" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${CW_EMAIL}\",\"api_key\":\"${CW_API_KEY}\"}" \
    | jq -r '.access_token // empty'
}

detect_server_id_local() {
  local conf u
  for conf in /home/master/applications/*/conf/server.nginx; do
    [[ -f "$conf" ]] || continue
    u=$(basename "$(dirname "$(dirname "$conf")")")
    for w in "${WANT_USERS[@]}"; do
      [[ "$u" == "$w" ]] || continue
      grep -oE '[a-zA-Z0-9_]+-[0-9]+-[0-9]+\.cloudwaysapps\.com' "$conf" | head -1 \
        | sed -n 's/.*-\([0-9]*\)-\([0-9]*\)\.cloudwaysapps\.com/\1/p'
      return 0
    done
  done
  return 1
}

TOKEN=$(api_token)
[[ -n "$TOKEN" ]] || { echo 'Failed to obtain API token' >&2; exit 1; }

SERVER_ID="${CW_SERVER_ID:-}"
if [[ -z "$SERVER_ID" ]]; then
  SERVER_ID=$(detect_server_id_local 2>/dev/null || true)
fi

json_apps_count() {
  echo "$1" | jq -r '.applications | length // 0' 2>/dev/null || echo 0
}

echo "Fetching application inventory ..."
APPS_JSON='{}'
if RAW=$(curl -sS --max-time 120 -H "Authorization: Bearer ${TOKEN}" \
  -H 'Accept: application/json' "${API_V2}/applications" 2>/dev/null); then
  if echo "$RAW" | jq -e . >/dev/null 2>&1; then
    APPS_JSON="$RAW"
  else
    echo "  [note] /applications returned non-JSON; using nginx + .php_version on this server." >&2
  fi
fi

if [[ "$(json_apps_count "$APPS_JSON")" -eq 0 ]]; then
  if V1_JSON=$(curl -sS --max-time 120 -H "Authorization: Bearer ${TOKEN}" \
    -H 'Accept: application/json' "${API_V1}/server" 2>/dev/null) \
    && echo "$V1_JSON" | jq -e . >/dev/null 2>&1; then
    APPS_JSON=$(echo "$V1_JSON" | jq -c '
      {applications: [ .servers[]? as $s | $s.apps[]? | . + {server_id: ($s.id|tostring)} ]}
    ' 2>/dev/null || echo '{}')
  fi
fi
if [[ "$(json_apps_count "$APPS_JSON")" -eq 0 ]]; then
  echo "  [note] API app list empty; resolving server_id/app_id from local nginx configs." >&2
fi

poll_operation() {
  local op_id="$1" api_root="$2"
  local i=0 url="${api_root}/operation/${op_id}"
  while (( i < POLL_MAX )); do
    sleep "$POLL_SEC"
    ((i++)) || true
    local body done
    body=$(curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "$url" 2>/dev/null || echo '{}')
    done=$(echo "$body" | jq -r '.operation.is_completed // "0"')
    echo "    poll ${op_id}: completed=${done} status=$(echo "$body" | jq -r '.operation.status // ""')"
    if [[ "$done" == "1" ]]; then
      return 0
    fi
  done
  return 1
}

post_php_version() {
  local server_id="$1" app_id="$2"
  local url body op_id http_code api_root
  for url in "${API_V2}/app/manage/php_version" "${API_V1}/app/manage/php_version"; do
    api_root="${url%/app/manage/php_version}"
    body=$(curl -sS --max-time 60 -X POST "$url" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "server_id=${server_id}" \
      --data-urlencode "app_id=${app_id}" \
      --data-urlencode "php_version=${TARGET_PHP}" \
      -w '\nHTTP:%{http_code}')
    http_code="${body##*HTTP:}"
    body="${body%HTTP:*}"
    op_id=$(echo "$body" | jq -r '.operation_id // empty' 2>/dev/null || true)
    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
      echo "    POST $url OK operation_id=${op_id:-n/a}"
      if [[ -n "$op_id" ]]; then
        poll_operation "$op_id" "$api_root" || return 1
      fi
      return 0
    fi
    echo "    POST $url -> HTTP $http_code $(echo "$body" | head -c 400)" >&2
  done
  return 1
}

resolve_app() {
  local want="$1"
  local sid aid php_ver
  sid=$(echo "$APPS_JSON" | jq -r --arg u "$want" '
    (.applications // [])[]
    | select((.sys_user // .sysUser // "") == $u)
    | (.server_id // .serverId // "") | tostring
  ' | head -1)
  aid=$(echo "$APPS_JSON" | jq -r --arg u "$want" '
    (.applications // [])[]
    | select((.sys_user // .sysUser // "") == $u)
    | (.id // .app_id // "") | tostring
  ' | head -1)
  php_ver=$(echo "$APPS_JSON" | jq -r --arg u "$want" '
    (.applications // [])[]
    | select((.sys_user // .sysUser // "") == $u)
    | (.php_version // .phpVersion // "")
  ' | head -1)

  if [[ (-z "$sid" || -z "$aid") && -f "/home/master/applications/${want}/conf/server.nginx" ]]; then
    local fqdn
    fqdn=$(grep -oE '[a-zA-Z0-9_]+-[0-9]+-[0-9]+\.cloudwaysapps\.com' \
      "/home/master/applications/${want}/conf/server.nginx" | head -1)
    if [[ -n "$fqdn" ]]; then
      sid=$(echo "$fqdn" | sed -n 's/.*-\([0-9]*\)-\([0-9]*\)\.cloudwaysapps\.com/\1/p')
      aid=$(echo "$fqdn" | sed -n 's/.*-\([0-9]*\)-\([0-9]*\)\.cloudwaysapps\.com/\2/p')
    fi
  fi
  if [[ -n "$SERVER_ID" ]]; then
    sid="$SERVER_ID"
  fi
  if [[ -z "$php_ver" && -f "/home/master/applications/${want}/.php_version" ]]; then
    php_ver=$(cat "/home/master/applications/${want}/.php_version")
  fi
  printf '%s\t%s\t%s\n' "$sid" "$aid" "$php_ver"
}

ok=0 fail=0 skip=0
for u in "${WANT_USERS[@]}"; do
  IFS=$'\t' read -r sid aid cur <<< "$(resolve_app "$u")"
  if [[ -z "$sid" || -z "$aid" ]]; then
    echo "x $u — could not resolve server_id/app_id (set CW_SERVER_ID or fix API scope)"
    ((fail++)) || true
    continue
  fi
  cur_norm=$(echo "$cur" | sed -n 's/.*\([0-9]\+\.[0-9]\+\).*/\1/p')
  if [[ "$cur_norm" == "$TARGET_PHP" ]]; then
    echo "- $u already PHP ${TARGET_PHP} (app_id=${aid})"
    ((skip++)) || true
    continue
  fi
  echo "-> $u  php=${cur:-?} -> ${TARGET_PHP}  server_id=${sid} app_id=${aid}"
  if (( DRY_RUN )); then
    continue
  fi
  if post_php_version "$sid" "$aid"; then
    ((ok++)) || true
  else
    ((fail++)) || true
  fi
  sleep "$SLEEP_BETWEEN"
done

echo "Finished: ${ok} upgraded, ${skip} skipped, ${fail} failed."
[[ "$fail" -eq 0 ]]
