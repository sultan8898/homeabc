#!/usr/bin/env bash
# Discover which Cloudways API call updates per-app PHP (read-only except probe POST/PUT/PATCH).
#
# Usage:
#   export CW_ACCESS_TOKEN='cw_...'
#   ./cw_php_api_probe.sh 1682474 3429072
#
# Prints HTTP status + message for each candidate URL/method/body.

set -euo pipefail

API_V2='https://api.cloudways.com/api/v2'
API_V1='https://api.cloudways.com/api/v1'

SERVER_ID="${1:?server_id}"
APP_ID="${2:?app_id}"
TARGET='8.3'

TOKEN="${CW_ACCESS_TOKEN:-}"
if [[ -z "$TOKEN" && -n "${CW_EMAIL:-}" && -n "${CW_API_KEY:-}" ]]; then
  TOKEN=$(curl -fsS -X POST "${API_V2}/oauth/access_token" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${CW_EMAIL}\",\"api_key\":\"${CW_API_KEY}\"}" \
    | jq -r '.access_token // empty')
fi
[[ -n "$TOKEN" ]] || { echo 'Set CW_ACCESS_TOKEN or CW_EMAIL+CW_API_KEY' >&2; exit 1; }

try_call() {
  local method="$1" url="$2" mode="$3" payload="$4"
  local body http
  if [[ "$mode" == "json" ]]; then
    body=$(curl -sS --max-time 45 -X "$method" "$url" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json' \
      -d "$payload" \
      -w '\nHTTP:%{http_code}')
  else
    body=$(curl -sS --max-time 45 -X "$method" "$url" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -H 'Accept: application/json' \
      --data "$payload" \
      -w '\nHTTP:%{http_code}')
  fi
  http="${body##*HTTP:}"
  body="${body%HTTP:*}"
  msg=$(echo "$body" | tr '\n' ' ' | head -c 160)
  printf '%-6s %-3s  %s\n  -> %s\n' "$http" "$method" "$url" "$msg"
}

echo "Auth check: GET /servers/${SERVER_ID} (correct v2 single-server route)"
try_call GET "${API_V2}/servers/${SERVER_ID}" json '{}'
echo "Note: GET /server/${SERVER_ID} returns plain text, not JSON — do not use it."
echo

echo "Probing PHP update candidates (target ${TARGET}) ..."
echo

candidates=(
  "PUT|${API_V2}/applications/${APP_ID}/php-version|json|{\"php_version\":\"${TARGET}\"}"
  "PUT|${API_V2}/applications/${APP_ID}/php-version?server_id=${SERVER_ID}|json|{\"php_version\":\"${TARGET}\"}"
  "PUT|${API_V2}/applications/${APP_ID}/php-version|json|{\"php_version\":\"${TARGET}\",\"server_id\":\"${SERVER_ID}\"}"
  "PUT|${API_V2}/applications/${APP_ID}/php-version|json|{\"phpVersion\":\"${TARGET}\",\"server_id\":\"${SERVER_ID}\"}"
  "PUT|${API_V2}/applications/${APP_ID}/php-version|json|{\"version\":\"${TARGET}\"}"
  "PATCH|${API_V2}/applications/${APP_ID}/php-version|json|{\"php_version\":\"${TARGET}\"}"
  "POST|${API_V2}/applications/${APP_ID}/php-version|json|{\"php_version\":\"${TARGET}\",\"server_id\":\"${SERVER_ID}\"}"
  "PUT|${API_V2}/application/${APP_ID}/php-version|json|{\"php_version\":\"${TARGET}\"}"
  "PUT|${API_V2}/apps/${APP_ID}/php-version|json|{\"php_version\":\"${TARGET}\",\"server_id\":\"${SERVER_ID}\"}"
  "POST|${API_V2}/apps/${APP_ID}/php-version|json|{\"php_version\":\"${TARGET}\",\"server_id\":\"${SERVER_ID}\"}"
  "PUT|${API_V2}/php_versions/${APP_ID}|json|{\"php_version\":\"${TARGET}\"}"
  "PUT|${API_V2}/php_versions/${APP_ID}|json|{\"version\":\"${TARGET}\",\"server_id\":\"${SERVER_ID}\"}"
  "POST|${API_V2}/php_versions/${APP_ID}|json|{\"php_version\":\"${TARGET}\",\"server_id\":\"${SERVER_ID}\"}"
  "POST|${API_V2}/app/php-version|json|{\"app_id\":\"${APP_ID}\",\"server_id\":\"${SERVER_ID}\",\"php_version\":\"${TARGET}\"}"
  "PUT|${API_V2}/app/php-version|json|{\"app_id\":\"${APP_ID}\",\"server_id\":\"${SERVER_ID}\",\"php_version\":\"${TARGET}\"}"
  "POST|${API_V2}/app/manage/php_version|form|server_id=${SERVER_ID}&app_id=${APP_ID}&php_version=${TARGET}"
  "PUT|${API_V2}/app/manage/php_version|form|server_id=${SERVER_ID}&app_id=${APP_ID}&php_version=${TARGET}"
  "POST|${API_V1}/app/manage/php_version|form|server_id=${SERVER_ID}&app_id=${APP_ID}&php_version=${TARGET}"
  "PUT|${API_V2}/server/${SERVER_ID}/applications/${APP_ID}/php-version|json|{\"php_version\":\"${TARGET}\"}"
  "PUT|${API_V2}/servers/${SERVER_ID}/applications/${APP_ID}/php-version|json|{\"php_version\":\"${TARGET}\"}"
  "PUT|${API_V2}/applications/${APP_ID}/php|json|{\"php_version\":\"${TARGET}\"}"
  "PUT|${API_V2}/applications/${APP_ID}/settings/php-version|json|{\"php_version\":\"${TARGET}\"}"
)

for spec in "${candidates[@]}"; do
  IFS='|' read -r method url mode payload <<< "$spec"
  try_call "$method" "$url" "$mode" "$payload"
done

echo
echo 'Look for HTTP 200/201/202 with operation_id in the response body.'
