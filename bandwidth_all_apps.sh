#!/usr/bin/env bash
# bandwidth_all_apps.sh — per-app bandwidth on a Cloudways server (last N days).
# Reads rotated *access.log* files under each application logs/ directory.
#
# Usage:
#   bash bandwidth_all_apps.sh
#   bash bandwidth_all_apps.sh --days 30 --top 25
#   bash bandwidth_all_apps.sh --app myapp123
#
# Run on the server as a user that can read /home/master/applications/*/logs/

set -euo pipefail

DAYS=30
TOP_URLS=25
ONLY_APP=""
APPS_ROOT="${APPS_ROOT:-/home/master/applications}"

usage() {
  sed -n '2,12p' "$0" | tail -n +2
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --days) DAYS="${2:?}"; shift 2 ;;
    --top) TOP_URLS="${2:?}"; shift 2 ;;
    --app) ONLY_APP="${2:?}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ ! -d "$APPS_ROOT" ]]; then
  echo "Not a Cloudways-style host: missing $APPS_ROOT" >&2
  exit 1
fi

AWK_BIN=$(command -v gawk || command -v awk || true)
[[ -n "$AWK_BIN" ]] || { echo "awk/gawk required" >&2; exit 1; }

# Date filtering needs GNU awk (mktime). Cloudways nodes usually have gawk.
AWK_AGG="$AWK_BIN"
DATE_FILTER=1
if command -v gawk >/dev/null; then
  AWK_AGG=gawk
else
  DATE_FILTER=0
  echo "Note: gawk not found; counting all data in rotated access logs (no --days cut-off)." >&2
fi

START_EPOCH=0
if [[ "$DATE_FILTER" -eq 1 ]]; then
  START_EPOCH=$(date --date="$DAYS days ago 00:00:00" +%s 2>/dev/null || date -v-"${DAYS}"d +%s)
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Primary customer domain from server.nginx (first non-cloudwaysapps server_name).
primary_domain() {
  local nginxconf="$1"
  [[ -f "$nginxconf" ]] || return 0
  local n primary="" fallback=""
  while read -r n; do
    [[ -z "$n" || "$n" == "_" || "$n" == "localhost" ]] && continue
    n="${n%;}"
    if [[ "$n" == *.cloudwaysapps.com ]]; then
      fallback="${fallback:-$n}"
    else
      primary="${primary:-$n}"
    fi
  done < <(grep -hoP 'server_name\s+\K[^;]+' "$nginxconf" 2>/dev/null | tr ' ' '\n')
  echo "${primary:-$fallback}"
}

# Collect access logs (current + rotated); skip noise files.
collect_logs() {
  local logdir="$1"
  [[ -d "$logdir" ]] || return 1
  find "$logdir" -maxdepth 1 -type f \
    \( -name '*access.log' -o -name '*access.log.*' \) \
    ! -name '*slow*' \
    2>/dev/null | sort -V
}

# One awk pass: bytes by request path + total; filter by date in $4.
aggregate_logs() {
  local domain="$1"
  shift
  local -a files=("$@")
  [[ ${#files[@]} -gt 0 ]] || return 0

  if [[ "$DATE_FILTER" -eq 1 ]]; then
    zcat -f "${files[@]}" 2>/dev/null | tr -d '\000' | "$AWK_AGG" -v start="$START_EPOCH" -v domain="$domain" '
      function mon(m) {
        return (m=="Jan")?1:(m=="Feb")?2:(m=="Mar")?3:(m=="Apr")?4:(m=="May")?5:(m=="Jun")?6:
               (m=="Jul")?7:(m=="Aug")?8:(m=="Sep")?9:(m=="Oct")?10:(m=="Nov")?11:12
      }
      function log_epoch(f,   t, a) {
        t = substr(f, 2, 20)
        split(t, a, /[:/]/)
        if (length(a[3]) != 4) return -1
        return mktime(sprintf("%04d %02d %02d %02d %02d %02d", a[3], mon(a[2]), a[1], a[4], a[5], a[6]))
      }
      function full_url(path,   host) {
        if (path ~ /^https?:\/\//) return path
        host = domain
        if (host == "") return path
        sub(/\?.*$/, "", path)
        if (path !~ /^\//) path = "/" path
        return "https://" host path
      }
      {
        if ($10 == "-" || $10 == "") next
        ep = log_epoch($4)
        if (ep < 0 || ep < start) next
        path = $7
        sub(/\?.*$/, "", path)
        url = full_url(path)
        bytes[url] += $10 + 0
        total += $10 + 0
      }
      END {
        printf "TOTAL\t%.0f\n", total
        for (u in bytes) printf "URL\t%s\t%.0f\n", u, bytes[u]
      }
    '
  else
    zcat -f "${files[@]}" 2>/dev/null | tr -d '\000' | "$AWK_AGG" -v domain="$domain" '
      function full_url(path,   host) {
        if (path ~ /^https?:\/\//) return path
        host = domain
        if (host == "") return path
        sub(/\?.*$/, "", path)
        if (path !~ /^\//) path = "/" path
        return "https://" host path
      }
      {
        if ($10 == "-" || $10 == "") next
        path = $7
        sub(/\?.*$/, "", path)
        url = full_url(path)
        bytes[url] += $10 + 0
        total += $10 + 0
      }
      END {
        printf "TOTAL\t%.0f\n", total
        for (u in bytes) printf "URL\t%s\t%.0f\n", u, bytes[u]
      }
    '
  fi
}

process_app() {
  local app_dir="$1"
  local app_name domain logdir out total line url bytes

  app_name=$(basename "$app_dir")
  domain=$(primary_domain "$app_dir/conf/server.nginx")
  logdir="$app_dir/logs"

  mapfile -t logfiles < <(collect_logs "$logdir" || true)
  if [[ ${#logfiles[@]} -eq 0 ]]; then
    echo "0 $app_name"
    return 0
  fi

  out="$TMPDIR/$app_name.tsv"
  aggregate_logs "$domain" "${logfiles[@]}" > "$out" || true

  total=$("$AWK_AGG" -F'\t' '$1=="TOTAL"{print $2; exit}' "$out" 2>/dev/null || echo 0)
  [[ -n "$total" && "$total" != 0 ]] || total=0
  printf '%s %s\n' "$total" "$app_name" >> "$TMPDIR/app_rank.txt"
}

# --- discover apps ---
if [[ -n "$ONLY_APP" ]]; then
  [[ -d "$APPS_ROOT/$ONLY_APP" ]] || { echo "App not found: $ONLY_APP" >&2; exit 1; }
  process_app "$APPS_ROOT/$ONLY_APP"
else
  for app_dir in "$APPS_ROOT"/*/; do
    [[ -d "$app_dir" ]] || continue
    process_app "$app_dir"
  done
fi

if [[ ! -f "$TMPDIR/app_rank.txt" ]]; then
  echo "No access logs found under $APPS_ROOT/*/logs/" >&2
  exit 0
fi

echo "Bandwidth report — last ${DAYS} day(s), apps highest traffic first"
echo "Generated: $(date -Is 2>/dev/null || date)"
echo ""

# Sort apps by total bytes descending
sort -t' ' -k1,1nr "$TMPDIR/app_rank.txt" | while read -r total app_name; do
  out="$TMPDIR/$app_name.tsv"
  domain=$(primary_domain "$APPS_ROOT/$app_name/conf/server.nginx")
  mb=$(awk -v t="$total" 'BEGIN { printf "%.3f", t/1024/1024 }')

  echo "================================================================================"
  echo "Application: $app_name"
  [[ -n "$domain" ]] && echo "Primary domain: $domain"
  echo "Total bandwidth: ${mb} MB (${total} bytes)"
  echo "--------------------------------------------------------------------------------"
  printf "%-12s  %s\n" "MB" "URL"
  echo "--------------------------------------------------------------------------------"

  if [[ -f "$out" ]]; then
    awk -F'\t' '$1=="URL"{print $3"\t"$2}' "$out" \
      | sort -t $'\t' -k1,1nr \
      | head -n "$TOP_URLS" \
      | awk -F'\t' '{ printf "%-12.3f  %s\n", $1/1024/1024, $2 }'
  fi
  echo ""
done

# Grand total across apps
grand=$(awk '{s+=$1} END {print s+0}' "$TMPDIR/app_rank.txt")
echo "================================================================================"
awk -v g="$grand" 'BEGIN { printf "All applications total: %.3f MB (%d bytes)\n", g/1024/1024, g }'
