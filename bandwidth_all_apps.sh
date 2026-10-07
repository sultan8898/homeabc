#!/usr/bin/env bash
# bandwidth_all_apps.sh — per-app bandwidth on a Cloudways server (last N days).
#
# Usage:
#   bash bandwidth_all_apps.sh                    # summary all apps + URL detail for top 5 apps
#   bash bandwidth_all_apps.sh --top-apps 10      # URL detail for top 10 apps
#   bash bandwidth_all_apps.sh --summary-only     # ranked app list only (fast)
#   bash bandwidth_all_apps.sh --days 30 --top 25 # top 25 URLs per detailed app
#
# Run on the server (reads /home/master/applications and *cloudwaysapps.com app dirs).

set -euo pipefail

DAYS=30
TOP_URLS=25
TOP_APPS=5
SUMMARY_ONLY=0
URL_DETAIL=1
ONLY_APP=""
APPS_ROOT="${APPS_ROOT:-/home/master/applications}"

usage() {
  cat <<'EOF'
bandwidth_all_apps.sh — bandwidth by application (sorted highest first)

  --days N          Window in days (default 30; needs gawk)
  --top-apps N      Show per-URL breakdown for top N apps (default 5; 0 = none)
  --top N           Top N URLs per app in breakdown (default 25)
  --summary-only    Only print ranked app table (fastest)
  --app NAME        Single application folder only
  -h, --help

Environment: APPS_ROOT (default /home/master/applications)
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --days) DAYS="${2:?}"; shift 2 ;;
    --top) TOP_URLS="${2:?}"; shift 2 ;;
    --top-apps) TOP_APPS="${2:?}"; shift 2 ;;
    --summary-only) SUMMARY_ONLY=1; URL_DETAIL=0; shift ;;
    --no-url-detail) URL_DETAIL=0; shift ;;
    --app) ONLY_APP="${2:?}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

AWK_BIN=$(command -v gawk || command -v awk || true)
[[ -n "$AWK_BIN" ]] || { echo "awk/gawk required" >&2; exit 1; }

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

collect_logs() {
  local logdir="$1"
  [[ -d "$logdir" ]] || return 1
  find "$logdir" -maxdepth 1 -type f \
    \( -name '*access.log' -o -name '*access.log.*' \) \
    ! -name '*slow*' \
    2>/dev/null | sort -V
}

# Fast pass: total bytes only (no per-URL map).
aggregate_total() {
  local domain="$1"
  shift
  local -a files=("$@")
  [[ ${#files[@]} -gt 0 ]] || { echo 0; return 0; }

  if [[ "$DATE_FILTER" -eq 1 ]]; then
    zcat -f "${files[@]}" 2>/dev/null | tr -d '\000' | "$AWK_AGG" -v start="$START_EPOCH" '
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
      { if ($10 == "-" || $10 == "") next
        ep = log_epoch($4)
        if (ep < 0 || ep < start) next
        total += $10 + 0
      }
      END { printf "%.0f", total+0 }
    '
  else
    zcat -f "${files[@]}" 2>/dev/null | tr -d '\000' | "$AWK_AGG" '
      { if ($10 == "-" || $10 == "") next; total += $10 + 0 }
      END { printf "%.0f", total+0 }
    '
  fi
}

aggregate_urls() {
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
      }
      END {
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
      }
      END {
        for (u in bytes) printf "URL\t%s\t%.0f\n", u, bytes[u]
      }
    '
  fi
}

# All application directories (dedupe symlinks).
discover_app_dirs() {
  declare -A _seen=()
  local d canon

  add_dir() {
    local p="$1"
    [[ -d "$p" ]] || return 0
    [[ -d "$p/logs" || -f "$p/conf/server.nginx" ]] || return 0
    canon=$(readlink -f "$p" 2>/dev/null || realpath "$p" 2>/dev/null || echo "$p")
    [[ -n "${_seen[$canon]:-}" ]] && return 0
    _seen[$canon]=1
    printf '%s\n' "$p"
  }

  if [[ -n "$ONLY_APP" ]]; then
    for base in "$APPS_ROOT" /home/*cloudwaysapps.com; do
      [[ -d "$base/$ONLY_APP" ]] && add_dir "$base/$ONLY_APP"
    done
    return 0
  fi

  if [[ -d "$APPS_ROOT" ]]; then
    for d in "$APPS_ROOT"/*/; do
      add_dir "${d%/}"
    done
  fi

  for d in /home/*cloudwaysapps.com/*/; do
    [[ -e "$d" ]] || continue
    add_dir "${d%/}"
  done
}

process_app_total() {
  local app_dir="$1"
  local app_name domain logdir total

  app_name=$(basename "$app_dir")
  domain=$(primary_domain "$app_dir/conf/server.nginx")
  logdir="$app_dir/logs"

  mapfile -t logfiles < <(collect_logs "$logdir" || true)
  if [[ ${#logfiles[@]} -eq 0 ]]; then
    total=0
  else
    total=$(aggregate_total "$domain" "${logfiles[@]}" || echo 0)
  fi
  [[ -n "$total" ]] || total=0

  printf '%s\t%s\t%s\t%s\n' "$total" "$app_name" "$domain" "$app_dir" >> "$TMPDIR/apps.meta"
}

# --- phase 1: totals for every app ---
app_count=0
while IFS= read -r app_dir; do
  [[ -n "$app_dir" ]] || continue
  process_app_total "$app_dir"
  app_count=$((app_count + 1))
done < <(discover_app_dirs)

if [[ "$app_count" -eq 0 ]]; then
  echo "No applications found under $APPS_ROOT or /home/*cloudwaysapps.com/*" >&2
  exit 1
fi

if [[ ! -s "$TMPDIR/apps.meta" ]]; then
  echo "No application metadata collected." >&2
  exit 1
fi

sort -t $'\t' -k1,1nr "$TMPDIR/apps.meta" > "$TMPDIR/apps.sorted"

echo "Bandwidth report — last ${DAYS} day(s)"
echo "Generated: $(date -Is 2>/dev/null || date)"
echo "Applications found: $app_count"
echo ""
echo "Rank  MB            App              Primary domain"
echo "----  ------------  ---------------  ----------------------------------------"

rank=0
while IFS=$'\t' read -r total app_name domain app_dir; do
  rank=$((rank + 1))
  mb=$(awk -v t="$total" 'BEGIN { printf "%.3f", t/1024/1024 }')
  printf "%4d  %12s  %-15s  %s\n" "$rank" "$mb" "$app_name" "${domain:-—}"
done < "$TMPDIR/apps.sorted"

grand=$(awk -F'\t' '{s+=$1} END {print s+0}' "$TMPDIR/apps.meta")
echo "----  ------------"
awk -v g="$grand" 'BEGIN { printf "      %12.3f MB total (all apps)\n", g/1024/1024 }'
echo ""

if [[ "$SUMMARY_ONLY" -eq 1 || "$URL_DETAIL" -eq 0 || "$TOP_APPS" -eq 0 ]]; then
  exit 0
fi

# --- phase 2: URL breakdown for top N apps only ---
echo "Per-URL breakdown for top ${TOP_APPS} app(s) (use --top-apps N or --summary-only)"
echo ""

n=0
while IFS=$'\t' read -r total app_name domain app_dir; do
  n=$((n + 1))
  [[ "$n" -le "$TOP_APPS" ]] || break

  mb=$(awk -v t="$total" 'BEGIN { printf "%.3f", t/1024/1024 }')
  echo "================================================================================"
  echo "#$n Application: $app_name  (${mb} MB total)"
  [[ -n "$domain" ]] && echo "Primary domain: $domain"
  echo "--------------------------------------------------------------------------------"
  printf "%-12s  %s\n" "MB" "URL"
  echo "--------------------------------------------------------------------------------"

  mapfile -t logfiles < <(collect_logs "$app_dir/logs" || true)
  if [[ ${#logfiles[@]} -eq 0 ]]; then
    echo "(no access logs)"
    echo ""
    continue
  fi

  aggregate_urls "$domain" "${logfiles[@]}" \
    | awk -F'\t' '$1=="URL"{print $3"\t"$2}' \
    | sort -t $'\t' -k1,1nr \
    | head -n "$TOP_URLS" \
    | awk -F'\t' '{ printf "%-12.3f  %s\n", $1/1024/1024, $2 }'
  echo ""
done < "$TMPDIR/apps.sorted"
