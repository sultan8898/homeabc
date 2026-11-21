#!/usr/bin/env bash
# sitecheck.sh - Cloudways per-app performance / TTFB root-cause diagnosis
# Merges sitecheck load tests with cw_ttfb_diag anatomy (warm/cold/origin,
# tagged probes that split network vs before-PHP vs inside-PHP, flag areas).
#
# Usage:
#   bash sitecheck.sh [APP] [hybrid|nginx] [quick|standard|full]
#   APP=cakcgucmse STACK=hybrid LEVEL=standard bash sitecheck.sh
#   curl -fsSL "<raw url>/sitecheck.sh" | APP=cakcgucmse STACK=nginx bash
#   curl -fsSL "<raw url>/sitecheck.sh" | bash -s -- cakcgucmse hybrid full
#
# Interactive prompts (reads /dev/tty so curl|bash works):
#   APP, STACK (hybrid|nginx), LEVEL, site URL / extra paths when missing.
#   If no URL is given, candidate paths are suggested from the PHP access log.
#
# Levels:
#   quick     read-only inspection + single-request TTFB anatomy (~1–2 min)
#   standard  adds short concurrency tests (5–20 parallel) + more probes
#   full      logged-in tests, FPM-direct compare, session ramp (needs WP_USER/WP_PASS)
#
# Optional env:
#   DOMAIN, BASE, URL / PATHS, EXTRA_URLS, LI_PATHS, WP_USER, WP_PASS,
#   RAMP_N="10 25", STAG=10, RAMP_DUR=30, CONC_DUR=12, STRACE=1,
#   N=8 (timing samples), PROBES=6 (tagged probes), FRONTIP, UA,
#   NOORIGIN=1, NOSAMPLE=1, SKIP_LOAD=1
#
# What it changes: nothing on the app. Temp files under /tmp (removed on exit).
# Report: /tmp/sitecheck-<app>-*.txt
# Load tests hit the live site and are skipped when the server is already busy.
set -u
export LC_ALL=C
SC_VERSION="2.0"

PROB=(); WARNS=(); INFOS=(); SKIPS=(); FLAGS=()
APP=${APP:-}; STACK=${STACK:-}; LEVEL=${LEVEL:-}
APPDIR=""; LOGDIR=""; DBN=""; DOMAIN=${DOMAIN:-}; BASE=${BASE:-}
POOL=""; PHPV=""; SOCK=""; MASTER=""; PREFIX=""
ORIGIN_AVG=""; LI_FIRST_AVG=""; REPORT=""
RAMP_P95=0; RAMP_BAD=0; RAMP_REDIR=0; RAMP_TOTAL=0; RAMP_WORKERS=0
ORIGIN_OK=0; FIRST_FINAL=""; SHOST=""; PUB=""; PLOG=""
N=${N:-8}; PROBES=${PROBES:-6}; FRONTIP=${FRONTIP:-}; UA=${UA:-}
SAMPLE=${NOSAMPLE:+0}; SAMPLE=${SAMPLE:-1}
NOORIGIN=${NOORIGIN:-0}; SKIP_LOAD=${SKIP_LOAD:-0}
PATHS=${PATHS:-}; EXTRA_URLS=${EXTRA_URLS:-}; URL=${URL:-}
ALLURLS=""; WARM_SLOW=0.6; COLD_SLOW=1.5
TP_N=""; TP_TTFB=""; TP_NET=""; TP_WAIT=""; TP_PHP=""; TP_BEF=""

prob() { PROB+=("$*"); echo "  [PROBLEM] $*"; }
warn() { WARNS+=("$*"); echo "  [WARN]    $*"; }
info() { INFOS+=("$*"); echo "  [info]    $*"; }
good() { echo "  [ok]      $*"; }
skip() { SKIPS+=("$*"); echo "  [skipped] $*"; }
sec()  { echo; echo "==== $* ===="; }
flag() { FLAGS+=("$1|$2"); }
num_gt() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a+0>b+0)}'; }
gt() { awk -v a="$1" -v b="$2" 'BEGIN{ if(a !~ /^[0-9.]+$/ || b !~ /^[0-9.]+$/) exit 1; exit !(a+0 > b+0) }'; }
ask() { local v=""; if [ -r /dev/tty ]; then read -r -p "$1" v < /dev/tty; fi; echo "$v"; }
ask_secret() { local v=""; if [ -r /dev/tty ]; then read -r -s -p "$1" v < /dev/tty; echo >&2; fi; echo "$v"; }
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }
memavail() { awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo; }
pct() { sort -n -k"$2","$2" "$1" | awk -v c="$2" -v p="$3" '{v[NR]=$c} END{ if(NR==0){print "n/a"; exit} i=int((p/100)*NR+0.999999); if(i<1)i=1; if(i>NR)i=NR; printf "%.3f", v[i] }'; }
addq() { local u="$1" q="$2" sep="?"; case "$u" in *\?*) sep="&";; esac; echo "${u}${sep}${q}"; }

usage() { cat << 'EOT'
sitecheck.sh - performance / TTFB root-cause diagnosis for one Cloudways app (run as root)
  bash sitecheck.sh [APP] [hybrid|nginx] [quick|standard|full]
  APP=cakcgucmse STACK=hybrid LEVEL=standard URL=https://example.com/ bash sitecheck.sh
  curl -fsSL "<raw url>/sitecheck.sh" | APP=cakcgucmse STACK=nginx bash
  curl -fsSL "<raw url>/sitecheck.sh" | bash -s -- cakcgucmse hybrid full

Missing APP, STACK, or URL are asked on the terminal. If URL/PATHS are empty,
candidate paths are suggested from the app's PHP access log (top by total PHP time).

LEVEL: quick (read-only + TTFB anatomy), standard (+ concurrency), full (+ logged-in ramp).
Optional: DOMAIN, BASE, URL, PATHS, EXTRA_URLS, LI_PATHS, WP_USER, WP_PASS,
          N, PROBES, FRONTIP, UA, RAMP_N, STAG, RAMP_DUR, CONC_DUR, STRACE=1,
          NOORIGIN=1, NOSAMPLE=1, SKIP_LOAD=1
EOT
}

# ---------- input / discovery ----------
get_inputs() {
  APP=${APP:-${1:-}}; STACK=${STACK:-${2:-}}; LEVEL=${LEVEL:-${3:-standard}}
  [ -n "$APP" ] || APP=$(ask "Application / DB name (the 10-letter app folder, e.g. cakcgucmse): ")
  [ -n "$STACK" ] || STACK=$(ask "Stack of this app [hybrid|nginx]: ")
  [ -n "$APP" ] || { echo "No application name given."; exit 1; }
  STACK=$(echo "$STACK" | tr 'A-Z' 'a-z')
  case "$STACK" in hybrid|nginx) ;; lightning) STACK=nginx ;; *) echo "STACK must be hybrid or nginx (got '$STACK')."; exit 1 ;; esac
  case "$LEVEL" in quick|standard|full) ;; *) echo "LEVEL must be quick, standard or full (got '$LEVEL')."; exit 1 ;; esac
  [[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] || N=8
  [ "$N" -gt 40 ] && N=40
  [[ "$PROBES" =~ ^[0-9]+$ ]] && [ "$PROBES" -ge 1 ] || PROBES=6
  [ "$PROBES" -gt 20 ] && PROBES=20
  [ -z "$UA" ] && UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
  case "$LEVEL" in
    quick) [ "${N}" -lt 4 ] || N=4; [ "${PROBES}" -lt 3 ] || PROBES=3 ;;
    standard) : ;;
    full) [ "$N" -lt 8 ] && N=8; [ "$PROBES" -lt 6 ] && PROBES=6 ;;
  esac
}

discover() {
  APPDIR=$(ls -d /home/*.cloudwaysapps.com/"$APP"/public_html 2>/dev/null | head -1)
  [ -n "$APPDIR" ] || APPDIR=$(find /home -maxdepth 4 -type d -path "*/$APP/public_html" 2>/dev/null | head -1)
  [ -n "$APPDIR" ] || { echo "Cannot find public_html for app '$APP' under /home."; exit 1; }
  LOGDIR=/home/master/applications/$APP/logs; [ -d "$LOGDIR" ] || LOGDIR=$(dirname "$APPDIR")/logs
  PUB="$APPDIR"
  MASTER=$(grep '^master_' /etc/passwd | head -1 | cut -d: -f1)
  CPUS=$(nproc); MEMTOTAL=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  MEM_FLOOR=$(( MEMTOTAL / 6 )); [ "$MEM_FLOOR" -lt 1500 ] && MEM_FLOOR=1500
  SOCK=$(ls /var/run/fpm-"$APP"-*.sock 2>/dev/null | head -1); POOL=""; PHPV=""
  if [ -n "$SOCK" ]; then POOL=$(basename "$SOCK" .sock | sed 's/^fpm-//'); local n=${POOL##*-}; PHPV="${n:0:1}.${n:1}"; fi
  PREFIX=$(grep -oP "table_prefix\s*=\s*'\K[^']+" "$APPDIR/wp-config.php" 2>/dev/null | head -1)
  DBN=$(grep -oP "DB_NAME'\s*,\s*'\K[^']+" "$APPDIR/wp-config.php" 2>/dev/null | head -1); DBN=${DBN:-$APP}
  PLOG=$LOGDIR/php-app.access.log
  SHOST=""
  if [ -z "${DOMAIN:-}" ] && [ -n "$MASTER" ]; then DOMAIN=$(WP option get home 2>/dev/null | head -1 | sed -E 's#^https?://##; s#/.*##'); fi
  [ -n "${DOMAIN:-}" ] || DOMAIN=$(grep -h server_name /etc/nginx/sites-available/"$APP" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')
  [ -n "${DOMAIN:-}" ] || DOMAIN=$(awk 'NR==1{print substr($NF,1,length($NF)-1)}' /home/master/applications/"$APP"/conf/server.nginx 2>/dev/null)
  [ -n "${DOMAIN:-}" ] || { echo "Cannot detect the domain, pass DOMAIN=example.com"; exit 1; }
  SHOST="$DOMAIN"
  if [ -n "${BASE:-}" ]; then :; elif [ -n "${URL:-}" ]; then
    case "$URL" in http://*|https://*) BASE=$(echo "$URL" | sed -E 's#(https?://[^/]+).*#\1#');;
      /*) BASE="https://$DOMAIN";; *) BASE="https://$URL"; BASE=$(echo "$BASE" | sed -E 's#(https?://[^/]+).*#\1#');; esac
  else BASE="https://$DOMAIN"; fi
  LI_PATHS=${LI_PATHS:-"/"}
  RAMP_N=${RAMP_N:-"10 25"}; STAG=${STAG:-10}; RAMP_DUR=${RAMP_DUR:-30}
  ORIGIN_OK=0; [ "$NOORIGIN" = 0 ] && ORIGIN_OK=1
}

WP() { ( cd "$APPDIR" && runuser -u "$MASTER" -- wp "$@" 2>/dev/null ); }

suggest_paths_from_logs() {
  local sug="$TMP/suggest_paths"
  : > "$sug"
  if [ -s "$PLOG" ]; then
    awk -F'"' '
      { split($3,a," "); if(a[6] !~ /^[0-9.]+$/) next
        split($2,r," "); p=$4; sub(/\?.*/,"",p)
        if(p ~ /\.(ico|txt|png|jpe?g|webp|svg|json|xml|map|css|js|woff2?)$/) next
        if(index(p,"admin-ajax.php")||index(p,"wp-cron.php")||index(p,"/wp-json")==1) next
        if(index(p,"/wp-admin")==1) next
        n[p]++; t[p]+=a[6]
      }
      END{ for(p in n) printf "%7.0f %5d %s\n", t[p], n[p], p }
    ' "$PLOG" | sort -rn | head -8 | tee "$TMP/suggest_raw" | awk '{print $3}' > "$sug"
  fi
  if [ ! -s "$sug" ]; then
    local AL; AL=$(ls -t "$LOGDIR"/backend_*access.log 2>/dev/null | head -1)
    if [ -n "$AL" ]; then
      awk -F'"' '{split($2,r," "); p=r[2]; sub(/\?.*/,"",p); if(p!=""&&p!="/favicon.ico") print p}' "$AL" \
        | sort | uniq -c | sort -rn | head -8 | awk '{print $2}' > "$sug"
    fi
  fi
  if [ -s "$sug" ]; then
    echo "  Candidate paths from this app's logs (total PHP time / hit count):"
    if [ -s "$TMP/suggest_raw" ]; then sed 's/^/    /' "$TMP/suggest_raw"; else sed 's/^/    /' "$sug"; fi
  else
    echo "  (no log-based path suggestions; defaulting to / and /wp-login.php)"
    printf '%s\n' "/" "/wp-login.php" > "$sug"
  fi
}

resolve_urls() {
  local ans path u
  if [ -n "${URL:-}" ]; then
    case "$URL" in http://*|https://*) ALLURLS="$URL";; /*) ALLURLS="$BASE$URL";; *) ALLURLS="https://$URL";; esac
  elif [ -n "${PATHS:-}" ]; then
    ALLURLS=""
    for path in $PATHS; do
      case "$path" in http://*|https://*) u="$path";; /*) u="$BASE$path";; *) u="$BASE/$path";; esac
      ALLURLS="$ALLURLS $u"
    done
    ALLURLS=$(echo "$ALLURLS" | sed 's/^ *//')
  else
    suggest_paths_from_logs
    echo
    ans=$(ask "Site URL or paths to diagnose (space/comma separated). Enter = use suggested paths above: ")
    if [ -z "$ans" ]; then
      ALLURLS=""
      while read -r path; do [ -n "$path" ] && ALLURLS="$ALLURLS $BASE$path"; done < "$TMP/suggest_paths"
      ALLURLS=$(echo "$ALLURLS" | sed 's/^ *//')
      [ -n "$ALLURLS" ] || ALLURLS="$BASE/"
    else
      ALLURLS=""
      ans=$(echo "$ans" | tr ',' ' ')
      for path in $ans; do
        case "$path" in
          http://*|https://*) u="$path";;
          /*) u="$BASE$path";;
          *) u="$BASE/$path";;
        esac
        ALLURLS="$ALLURLS $u"
      done
      ALLURLS=$(echo "$ALLURLS" | sed 's/^ *//')
    fi
  fi
  if [ -n "${EXTRA_URLS:-}" ]; then
    for path in $(echo "$EXTRA_URLS" | tr ',' ' '); do
      case "$path" in http://*|https://*) u="$path";; /*) u="$BASE$path";; *) u="$BASE/$path";; esac
      ALLURLS="$ALLURLS $u"
    done
  fi
  # Derive PATHS list (path-only) for concurrency / single samples that still use PATHS
  if [ -z "${PATHS:-}" ]; then
    PATHS=""
    for u in $ALLURLS; do
      path=$(echo "$u" | sed -E 's#^https?://[^/]+##'); [ -z "$path" ] && path="/"
      PATHS="$PATHS $path"
    done
    PATHS=$(echo "$PATHS" | sed 's/^ *//')
  fi
  FIRST_FINAL=""
}

# ---------- timing helpers (sitecheck) ----------
sample() { # label url n [curl args]
  local lab=$1 url=$2 n=$3; shift 3; local t i
  t=$(for i in $(seq 1 "$n"); do curl -sk -A "$UA" -o /dev/null "$@" -w '%{time_starttransfer} %{time_pretransfer} %{http_code}\n' "$url"; done)
  if ! printf '%s\n' "$t" | grep -qv ' 000$'; then echo "  $lab: no response (connection failed, port closed or blocked)"; LAST_AVG=0; LAST_WAIT=0; return; fi
  printf '%s\n' "$t" | awk -v l="$lab" '{s+=$1;w+=($1-$2);if(min==""||$1<min)min=$1;if($1>max)max=$1;c[$3]++} END{printf "  %-34s n=%d ttfb avg=%.3f min=%.3f max=%.3f  server-wait avg=%.3f  codes:",l,NR,s/NR,min,max,w/NR; for(k in c)printf " %s x%d",k,c[k]; print ""}'
  LAST_AVG=$(printf '%s\n' "$t" | awk '{s+=$1} END{printf "%.3f",s/NR}')
  LAST_WAIT=$(printf '%s\n' "$t" | awk '{w+=($1-$2)} END{printf "%.3f",w/NR}')
}

conc() {
  local lab=$1 url=$2 n=$3 dur=$4; shift 4
  local out="$TMP/conc.$RANDOM" end=$(( $(date +%s) + dur )) w pids=""
  : > "$out"
  for w in $(seq 1 "$n"); do
    ( while [ "$(date +%s)" -lt "$end" ]; do
        u="${url//@@/$RANDOM$RANDOM}"
        curl -sk -A "$UA" -o /dev/null "$@" -w '%{http_code} %{time_starttransfer}\n' "$u" >> "$out"
      done ) &
    pids="$pids $!"
  done
  wait $pids
  sort -k2 -n "$out" | awk -v l="$lab" -v n="$n" -v d="$dur" '{a[NR]=$2;s+=$2;c[$1]++} END{ if(NR==0){print "  " l ": no responses"; exit} i=int(NR*0.95); if(i<1)i=1; printf "  %-30s N=%-2d reqs=%d avg=%.2f p50=%.2f p95=%.2f max=%.2f codes:",l,n,NR,s/NR,a[int((NR+1)/2)],a[i],a[NR]; for(k in c)printf " %s x%d",k,c[k]; print ""}'
  LAST_AVG=$(awk '{s+=$2} END{if(NR)printf "%.3f",s/NR; else print 0}' "$out")
  LAST_P95=$(sort -k2 -n "$out" | awk '{a[NR]=$2} END{i=int(NR*0.95); if(i<1)i=1; printf "%.3f",a[i]}')
  LAST_BAD=$(awk '($1>=500||$1==0){b++} END{print b+0}' "$out")
  rm -f "$out"
}

safe_to_load() {
  local l; l=$(cut -d' ' -f1 /proc/loadavg)
  if [ "$SKIP_LOAD" = 1 ]; then echo "SKIP_LOAD=1"; return 1; fi
  if awk -v l="$l" -v c="$CPUS" 'BEGIN{exit !(l>c*0.6)}'; then echo "load average $l is above 60% of $CPUS cores"; return 1; fi
  if [ "$(memavail)" -lt "$MEM_FLOOR" ]; then echo "available memory is below ${MEM_FLOOR} MB"; return 1; fi
  return 0
}

vsnap() { command -v varnishstat >/dev/null && varnishstat -1 2>/dev/null | awk '{print $1,$2}' | sort > "$1"; }
vdiff() { [ -s "$1" ] && [ -s "$2" ] && join "$1" "$2" | awk '$3!=$2{print $1, $3-$2}' | grep -E 'MAIN\.(client_req|busy_sleep|busy_wakeup|s_pass|cache_miss|cache_hitmiss|cache_hit)$'; }

# ---------- TTFB anatomy (from cw_ttfb_diag) ----------
W='%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{remote_ip}'
HF=""
url_parts() {
  local u="$1" hp
  hp=$(echo "$u" | sed -E 's#^https?://([^/]+).*#\1#'); HOST=${hp%%:*}
  case "$hp" in *:*) PORT=${hp##*:};; *) case "$u" in http://*) PORT=80;; *) PORT=443;; esac;; esac
  CR=(); [ -n "$FRONTIP" ] && CR=(--resolve "$HOST:$PORT:$FRONTIP")
}
probe() { local u="$1"; shift; local o rc; o=$(curl -s -A "$UA" -m 60 -o /dev/null -D "$HF" -w "$W" "$@" "$u" </dev/null); rc=$?; echo "$rc $o"; }
hdr() { grep -i "^$1:" "$HF" 2>/dev/null | head -1 | cut -d' ' -f2- | tr -d '\r'; }
cookie_names() { grep -i '^set-cookie:' "$HF" 2>/dev/null | sed -E 's/^[Ss]et-[Cc]ookie: *([^=]+)=.*/\1/' | tr -d '\r' | sort -u | tr '\n' ' '; }

series() {
  local label="$1" u="$2" mode="$3" n="$4" i line xc ag
  : > "$TMP/rows"
  for i in $(seq 1 "$n"); do
    case "$mode" in
      warm)   line=$(probe "$u" "${CR[@]}");;
      cold)   line=$(probe "$(addq "$u" "cwdiag=$RANDOM$RANDOM")" "${CR[@]}");;
      origin) line=$(probe "$(addq "$u" "cwdiag=$RANDOM$RANDOM")" -k --resolve "$HOST:$PORT:127.0.0.1");;
    esac
    xc=$(hdr x-cache | awk '{print $1}' | tr -d ','); [ -z "$xc" ] && xc=$(hdr cf-cache-status | awk '{print $1}'); ag=$(hdr age)
    echo "$line" | awk -v xc="${xc:--}" -v ag="${ag:--}" '{ip=($9==""?"-":$9); nw=($5>0?$5:$4); w=$6-nw; if(w<0)w=0; printf "%s %s %s %s %s %s %s %s %s %s %s %.3f %.3f\n",$1,$2,$3,$4,$5,$6,$7,$8,ip,xc,ag,w,nw}' >> "$TMP/rows"
    sleep 0.15
  done
  S_N=$(wc -l < "$TMP/rows")
  S_FAIL=$(awk '$1!=0 || $2=="000" || $2>=400{c++} END{print c+0}' "$TMP/rows")
  S_CODES=$(awk '{c[$2]++} END{for(k in c) printf "%s:%d ", k, c[k]}' "$TMP/rows")
  S_XC=$(awk '{c[$10]++} END{for(k in c) printf "%s:%d ", k, c[k]}' "$TMP/rows")
  S_HIT=$(awk 'toupper($10)=="HIT"{c++} END{print c+0}' "$TMP/rows")
  S_T50=$(pct "$TMP/rows" 6 50); S_T95=$(pct "$TMP/rows" 6 95); S_TMAX=$(pct "$TMP/rows" 6 100)
  S_W50=$(pct "$TMP/rows" 12 50); S_W95=$(pct "$TMP/rows" 12 95); S_NET50=$(pct "$TMP/rows" 13 50); S_DNS50=$(pct "$TMP/rows" 3 50)
  printf "  %-8s n=%s failed=%s codes=[%s] cache=[%s]\n" "$label" "$S_N" "$S_FAIL" "${S_CODES% }" "${S_XC% }"
  printf "           ttfb s: p50 %s  p95 %s  max %s   | network p50 %s (dns %s)  | server wait p50 %s  p95 %s\n" \
    "$S_T50" "$S_T95" "$S_TMAX" "$S_NET50" "$S_DNS50" "$S_W50" "$S_W95"
}

test_url_anatomy() {
  local U="$1" code0 loc rcc FINAL ck cc xcany warm_w cold_w cold_net orig_w
  url_parts "$U"; echo; echo "---- $U ----"
  probe "$U" "${CR[@]}" > "$TMP/first"; read -r _ code0 _ < "$TMP/first"
  if [[ "${code0:-}" =~ ^3 ]]; then
    loc=$(hdr location); rcc=$(hdr cache-control)
    echo "  this URL redirects ($code0) to: $loc   [cache-control: ${rcc:-none}; x-cache: $(hdr x-cache)]"
    series "redirect" "$U" warm 3
    if echo "$rcc" | grep -qiE 'no-store|private|no-cache' || { [ -n "$(hdr x-cache)" ] && [ "$S_HIT" = 0 ]; }; then
      flag "CACHE" "The redirect at $U is not served from cache on repeat requests"
      warn "redirect at $U is uncacheable / never HIT"
    fi
    FINAL=$(curl -s -A "$UA" -m 60 -o /dev/null -L -w '%{url_effective}' "${CR[@]}" "$U" </dev/null)
    if [ -n "$FINAL" ] && [ "$FINAL" != "$U" ]; then echo "  testing the final URL: $FINAL"; U="$FINAL"; url_parts "$U"; fi
  fi
  # Keep the first resolved (post-redirect) URL for tagged probes
  [ -z "$FIRST_FINAL" ] && FIRST_FINAL="$U"

  series "warm" "$U" warm "$N"; warm_w=$S_W50
  ck=$(cookie_names); cc=$(hdr cache-control); xcany=$(hdr x-cache)
  echo "  headers: server=$(hdr server) via=$(hdr via) cache-control=${cc:-none} x-cache=${xcany:-none} age=$(hdr age) cf-cache-status=$(hdr cf-cache-status)"
  echo "  cookies set (names only): ${ck:-none}"
  [ "$S_FAIL" -gt 0 ] && { flag "TTFB" "$S_FAIL of $S_N normal requests to $U failed (codes: ${S_CODES% })"; warn "$S_FAIL of $S_N warm requests failed"; }
  if [ -n "$xcany" ] && [ "$S_HIT" = 0 ] && [[ "${code0:-200}" =~ ^[23] ]]; then
    flag "CACHE" "$U: none of $S_N normal requests was an x-cache HIT"
    warn "$U never cache HIT across $S_N warm requests"
  fi
  echo "$cc" | grep -qiE 'no-store|private' && { flag "CACHE" "$U: cache-control '$cc' can stop page caching"; warn "cache-control '$cc' on $U"; }
  [ -n "$ck" ] && [ "$S_HIT" = 0 ] && { flag "CACHE" "$U: response sets cookies ($ck) and is never a cache hit"; info "cookies on $U: $ck"; }
  echo "$ck" | grep -q 'PHPSESSID' && { flag "CACHE" "$U: PHPSESSID set on a public page"; warn "PHPSESSID set on public page $U"; }
  gt "$warm_w" "$WARM_SLOW" && { flag "TTFB" "$U: warm server wait ${warm_w}s p50 with $S_HIT/$S_N cache hits"; warn "warm server-wait p50 ${warm_w}s for $U"; }

  series "cold" "$U" cold "$N"; cold_w=$S_W50; cold_net=$S_NET50
  [ "$S_FAIL" -gt 0 ] && flag "TTFB" "$S_FAIL of $S_N uncached requests to $U failed"
  gt "$cold_w" "$COLD_SLOW" && { flag "TTFB" "$U: uncached server wait ${cold_w}s p50 (p95 ${S_W95}s)"; prob "uncached TTFB/server-wait for $U is ${cold_w}s p50"; }
  if [ "$N" -ge 6 ] && gt "$S_W95" "$(awk -v a="$cold_w" 'BEGIN{print a*3}')" && gt "$S_W95" 1; then
    flag "STALL" "$U: uncached wait varies a lot (p50 ${cold_w}s, p95 ${S_W95}s)"
    warn "high TTFB variance on $U (p50 ${cold_w}s / p95 ${S_W95}s)"
  fi
  gt "$cold_net" 0.3 && { flag "PATH" "$U: connection setup p50 ${cold_net}s"; warn "network setup ${cold_net}s p50 for $U"; }
  gt "$S_DNS50" 0.1 && { flag "PATH" "$U: DNS p50 ${S_DNS50}s"; warn "DNS ${S_DNS50}s p50"; }
  if [ "$ORIGIN_OK" = 1 ] && [ "$HOST" = "$SHOST" -o "$HOST" = "$DOMAIN" ]; then
    series "origin" "$U" origin "$N"; orig_w=$S_W50
    if gt "$cold_w" "$(awk -v a="$orig_w" 'BEGIN{print a+0.4}')" && gt "$cold_w" "$(awk -v a="$orig_w" 'BEGIN{print a*1.5}')"; then
      flag "PATH" "$U: public uncached wait ${cold_w}s vs origin ${orig_w}s (front path adds the difference)"
      warn "front path adds ~$(awk -v a="$cold_w" -v b="$orig_w" 'BEGIN{printf "%.2f",a-b}')s vs origin for $U"
    fi
  fi
}

# ---------- tagged probes + sampling ----------
SELFRE=""; S_TOT=0; S_DB=0; S_OUT=0
db_sample() {
  local r
  r=$(mysql -N -e "SELECT LEFT(INFO,160) FROM information_schema.processlist WHERE db='$DBN' AND COMMAND<>'Sleep' AND INFO IS NOT NULL AND INFO NOT LIKE '%information_schema.processlist%'" 2>/dev/null)
  if [ -n "$r" ]; then S_DB=$((S_DB+1)); echo "$r" | sed -E "s/'[^']*'/?/g; s/\"[^\"]*\"/?/g; s/[0-9]+/N/g" | cut -c1-100 >> "$TMP/db_fp"; fi
}
out_sample() {
  local pids r
  pids=$(pgrep -u "$APP" -f 'php-fpm: pool' 2>/dev/null | paste -sd'|'); [ -z "$pids" ] && return
  r=$(ss -tnpH 2>/dev/null | grep -E "pid=($pids)," | awk '$1=="ESTAB" || $1=="SYN-SENT"{print $5}' | grep -vE '^(127\.|\[::1\]|10\.|192\.168\.)')
  [ -n "$SELFRE" ] && r=$(echo "$r" | grep -vE "^($SELFRE):")
  if [ -n "$r" ]; then S_OUT=$((S_OUT+1)); echo "$r" | sort -u >> "$TMP/out_rem"; fi
}
sampler() { local pid="$1"; while kill -0 "$pid" 2>/dev/null; do S_TOT=$((S_TOT+1)); db_sample; out_sample; sleep 0.2; done; }

tagged_probes() {
  local u="$1" i tag pid code tls conn ttfb net wait dur bef
  url_parts "$u"; : > "$TMP/tp"; : > "$TMP/db_fp"; : > "$TMP/out_rem"; S_TOT=0; S_DB=0; S_OUT=0
  echo; echo "== TAGGED PROBES: $PROBES uncached probes matched to PHP log (${PLOG##*/}) =="
  if [ ! -r "$PLOG" ]; then echo "  (php access log not readable: $PLOG)"; skip "tagged probes need readable $PLOG"; return; fi
  for i in $(seq 1 "$PROBES"); do
    tag=cwtrace$(date +%s)$RANDOM
    ( curl -s -A "$UA" -m 120 -o /dev/null -w '%{http_code} %{time_connect} %{time_appconnect} %{time_starttransfer}' "${CR[@]}" "$(addq "$u" "${tag}=1")" > "$TMP/tp_r" 2>/dev/null || echo "000 0 0 0" > "$TMP/tp_r" ) &
    pid=$!
    if [ "$SAMPLE" = 1 ]; then sampler "$pid"; fi
    wait "$pid"; read -r code conn tls ttfb < "$TMP/tp_r"
    echo "$tag $code $conn $tls $ttfb" >> "$TMP/tp"; sleep 0.8
  done
  sleep 1
  printf "  %-4s %-6s %-9s %-9s %-11s %-10s %-12s\n" "#" "code" "ttfb s" "network" "server wait" "inside PHP" "before PHP"
  : > "$TMP/tp2"; i=0
  while read -r tag code conn tls ttfb; do
    i=$((i+1)); dur=$(grep -F "$tag" "$PLOG" | head -1 | awk -F'"' '{split($3,a," "); print a[6]}')
    net=$(awk -v c="$conn" -v t="$tls" 'BEGIN{printf "%.3f", (t+0>0?t:c)}')
    wait=$(awk -v f="$ttfb" -v n="$net" 'BEGIN{w=f-n; if(w<0)w=0; printf "%.3f", w}')
    if [[ "$dur" =~ ^[0-9.]+$ ]]; then
      bef=$(awk -v w="$wait" -v d="$dur" 'BEGIN{b=w-d; if(b<0)b=0; printf "%.3f", b}')
      echo "$ttfb $net $wait $dur $bef" >> "$TMP/tp2"
    else dur="-"; bef="-"; fi
    printf "  %-4s %-6s %-9s %-9s %-11s %-10s %-12s\n" "$i" "$code" "$ttfb" "$net" "$wait" "$dur" "$bef"
  done < "$TMP/tp"
  TP_N=$(wc -l < "$TMP/tp2")
  if [ "$TP_N" -eq 0 ]; then echo "  (no probe found in PHP log: page may bypass PHP or log format differs)"; return; fi
  TP_TTFB=$(pct "$TMP/tp2" 1 50); TP_NET=$(pct "$TMP/tp2" 2 50); TP_WAIT=$(pct "$TMP/tp2" 3 50)
  TP_PHP=$(pct "$TMP/tp2" 4 50); TP_BEF=$(pct "$TMP/tp2" 5 50)
  echo "  medians over $TP_N matched probes: ttfb ${TP_TTFB}s | network ${TP_NET}s | server wait ${TP_WAIT}s = before PHP ${TP_BEF}s + inside PHP ${TP_PHP}s"
  TP_SLOWBEF=$(awk '$5>1 && $5>$4{c++} END{print c+0}' "$TMP/tp2"); TP_SLOWPHP=$(awk '$4>1{c++} END{print c+0}' "$TMP/tp2")
  echo "  probes >1s before PHP: $TP_SLOWBEF/$TP_N; probes >1s inside PHP: $TP_SLOWPHP/$TP_N"
  [ "$TP_SLOWBEF" -ge 1 ] && [ $((TP_SLOWBEF*4)) -ge "$TP_N" ] && {
    flag "QUEUE" "$TP_SLOWBEF of $TP_N probes waited >1s before PHP started"
    warn "intermittent queue before PHP ($TP_SLOWBEF/$TP_N probes)"
  }
  [ "$TP_SLOWPHP" -ge 1 ] && [ $((TP_SLOWPHP*4)) -ge "$TP_N" ] && {
    flag "PHP" "$TP_SLOWPHP of $TP_N probes spent >1s inside PHP"
    warn "PHP itself slow on $TP_SLOWPHP/$TP_N probes"
  }
  if gt "$TP_BEF" 0.3 && gt "$TP_BEF" "$(awk -v p="$TP_PHP" 'BEGIN{print p*0.5}')"; then
    flag "QUEUE" "Median ${TP_BEF}s before PHP vs ${TP_PHP}s inside PHP"
    warn "median before-PHP ${TP_BEF}s dominates inside-PHP ${TP_PHP}s"
  fi
  if [ "$SAMPLE" = 1 ] && [ "$S_TOT" -gt 0 ]; then
    echo "  sampling during probes ($S_TOT samples): MariaDB active $S_DB ($((S_DB*100/S_TOT))%), outside conn $S_OUT ($((S_OUT*100/S_TOT))%)"
    [ "$S_DB" -gt 0 ] && { echo "  query patterns:"; sort "$TMP/db_fp" | uniq -c | sort -nr | head -5 | sed 's/^/    /'; }
    [ "$S_OUT" -gt 0 ] && { echo "  outside addresses:"; sort "$TMP/out_rem" | uniq -c | sort -nr | head -5 | sed 's/^/    /'; }
    [ $((S_DB*100/S_TOT)) -ge 40 ] && { flag "DB" "MariaDB busy in $((S_DB*100/S_TOT))% of probe samples"; warn "DB busy during uncached probes"; }
    [ $((S_OUT*100/S_TOT)) -ge 30 ] && { flag "OUTSIDE" "Outside connections in $((S_OUT*100/S_TOT))% of samples"; warn "outside calls during uncached probes"; }
  fi
}

# ---------- embedded helpers ----------
write_helpers() {
cat > "$TMP/fcgi.py" << 'PYEOF'
import os, socket, struct, sys, time
def nv(n, v):
    n = n.encode(); v = v.encode()
    f = lambda x: bytes([x]) if x < 128 else struct.pack('>I', x | 0x80000000)
    return f(len(n)) + f(len(v)) + n + v
def rec(t, c): return struct.pack('>BBHHBx', 1, t, 1, len(c), 0) + c
def rd(s, n):
    b = b''
    while len(b) < n:
        x = s.recv(n - len(b))
        if not x: raise EOFError
        b += x
    return b
def call(sock, script, host, uri, cookie):
    env = {'GATEWAY_INTERFACE': 'CGI/1.1', 'SERVER_PROTOCOL': 'HTTP/1.1', 'REQUEST_METHOD': 'GET',
           'SCRIPT_FILENAME': script, 'SCRIPT_NAME': '/' + script.rsplit('/', 1)[1],
           'DOCUMENT_ROOT': script.rsplit('/', 1)[0], 'REQUEST_URI': uri, 'QUERY_STRING': '',
           'HTTP_HOST': host, 'SERVER_NAME': host, 'SERVER_PORT': '443', 'HTTPS': 'on', 'REQUEST_SCHEME': 'https',
           'REMOTE_ADDR': '127.0.0.1', 'HTTP_COOKIE': cookie, 'HTTP_X_FORWARDED_PROTO': 'https',
           'HTTP_ACCEPT_ENCODING': 'identity'}
    s = socket.socket(socket.AF_UNIX); s.settimeout(60); s.connect(sock)
    t0 = time.time()
    s.sendall(rec(1, struct.pack('>HB5x', 1, 0)) + rec(4, b''.join(nv(k, v) for k, v in env.items())) + rec(4, b'') + rec(5, b''))
    first = None; out = b''; err = b''
    while True:
        _, t, _, cl, pl, _ = struct.unpack('>BBHHBB', rd(s, 8))
        c = rd(s, cl)
        if pl: rd(s, pl)
        if t == 6 and c:
            if first is None: first = time.time() - t0
            out += c
        if t == 7: err += c
        if t == 3: break
    s.close()
    head, _, body = out.partition(b'\r\n\r\n')
    if b'Status: ' in head: code = head.split(b'Status: ')[1][:3].decode()
    elif b'Location:' in head: code = '302'
    else: code = '200'
    return code, first, body.decode(errors='replace'), err.decode(errors='replace')
mode = sys.argv[1]
if mode == 'php':
    code, t, body, err = call(sys.argv[2], sys.argv[3], 'localhost', '/' + sys.argv[3].rsplit('/', 1)[1], '')
    print(body.strip() if body.strip() else 'error=status %s %s' % (code, err[:200].replace('\n', ' ')))
else:
    sock, app, host, uri, n = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])
    ck = os.environ.get('SC_COOKIE', '')
    cs = []; ts = []
    for i in range(n):
        c, t, _, _ = call(sock, app + '/index.php', host, uri, ck); cs.append(c); ts.append('%.4f' % t)
    print('CODES ' + ' '.join(cs) + ' TIMES ' + ' '.join(ts))
PYEOF
cat > "$TMP/opc.php" << 'PHPEOF'
<?php
header('Content-Type: text/plain');
if (!function_exists('opcache_get_status')) { echo "opcache=missing\n"; exit; }
$s = opcache_get_status(true);
if (!$s) { echo "opcache=off\n"; exit; }
$c = opcache_get_configuration()['directives'];
$m = $s['memory_usage']; $st = $s['opcache_statistics'];
$e = array_map('strtolower', get_loaded_extensions());
$out = array(
 'used_mb' => round($m['used_memory']/1048576), 'free_mb' => round($m['free_memory']/1048576),
 'wasted_pct' => round($m['current_wasted_percentage'], 1), 'limit_mb' => round($c['opcache.memory_consumption']/1048576),
 'scripts' => $st['num_cached_scripts'], 'max_keys' => $st['max_cached_keys'], 'hit_rate' => round($st['opcache_hit_rate'], 1),
 'oom_restarts' => $st['oom_restarts'], 'hash_restarts' => $st['hash_restarts'], 'manual_restarts' => $st['manual_restarts'],
 'cache_full' => $s['cache_full'] ? 'true' : 'false', 'validate_timestamps' => $c['opcache.validate_timestamps'] ? 'true' : 'false',
 'revalidate_freq' => $c['opcache.revalidate_freq'], 'jit' => ini_get('opcache.jit'),
 'xdebug' => in_array('xdebug', $e) ? 1 : 0, 'newrelic' => in_array('newrelic', $e) ? 1 : 0, 'i360' => in_array('i360', $e) ? 1 : 0,
 'realpath_cache_size' => ini_get('realpath_cache_size'), 'php' => PHP_VERSION);
foreach ($out as $k => $v) echo "$k=$v\n";
$n = array();
foreach ($s['scripts'] as $p => $x) { if (preg_match('#/([a-z]{10})/public_html/#', $p, $mm)) { $n[$mm[1]] = (isset($n[$mm[1]]) ? $n[$mm[1]] : 0) + 1; } }
arsort($n); foreach ($n as $k => $v) echo "app_$k=$v\n";
PHPEOF
cat > "$TMP/app.php" << 'PHPEOF'
<?php
echo "home=", home_url(), "\n";
echo "wp=", get_bloginfo('version'), "\n";
$pl = (array) get_option('active_plugins', array());
echo "plugin_count=", count($pl), "\n";
echo "plugins=", implode(',', array_map(function($p){ return dirname($p) === '.' ? $p : dirname($p); }, $pl)), "\n";
echo "dropin_object_cache=", file_exists(WP_CONTENT_DIR.'/object-cache.php') ? 1 : 0, "\n";
echo "dropin_advanced_cache=", file_exists(WP_CONTENT_DIR.'/advanced-cache.php') ? 1 : 0, "\n";
$mu = glob(WPMU_PLUGIN_DIR.'/*.php'); echo "mu_plugins=", implode(',', array_map('basename', $mu ? $mu : array())), "\n";
$theme = wp_get_theme();
echo "theme=", $theme->get_stylesheet(), "\n";
echo "theme_name=", $theme->get('Name'), "\n";
echo "theme_parent=", $theme->parent() ? $theme->parent()->get_stylesheet() : '', "\n";
$c = _get_cron_array(); $n = 0; $o = 0; $now = time();
if (is_array($c)) foreach ($c as $t => $h) { if (!is_array($h)) continue; foreach ($h as $k => $v) { $n += count($v); if ($t < $now - 600) $o += count($v); } }
echo "cron_events=$n\ncron_overdue=$o\n";
echo "wp_debug=", (defined('WP_DEBUG') && WP_DEBUG) ? 1 : 0, "\n";
echo "disable_wp_cron=", (defined('DISABLE_WP_CRON') && DISABLE_WP_CRON) ? 1 : 0, "\n";
echo "wp_cache=", (defined('WP_CACHE') && WP_CACHE) ? 1 : 0, "\n";
PHPEOF
chmod 644 "$TMP/fcgi.py" "$TMP/opc.php" "$TMP/app.php"
}

# ---------- sections ----------
sec_system() {
  sec "1. SYSTEM"
  echo "  host=$(hostname) cpus=$CPUS mem_total=${MEMTOTAL}MB $(uptime | sed 's/^ *//')"
  free -m | awk 'NR<=3{print "  " $0}'
  local l sw oom vm MEMAVAIL SWT SWU SI SO a3 r line
  l=$(cut -d' ' -f1 /proc/loadavg)
  if awk -v l="$l" -v c="$CPUS" 'BEGIN{exit !(l>c*0.7)}'; then warn "load average $l is above 70% of $CPUS cores right now"; else good "load average $l on $CPUS cores"; fi
  gt "$l" "$CPUS" && flag "LOAD" "1-minute load $l exceeds CPU count $CPUS"
  sw=$(free -m | awk '/Swap/{print $3}'); [ "${sw:-0}" -gt 200 ] && { warn "swap in use: ${sw} MB"; flag "MEMORY" "${sw} MB swap in use"; }
  SWT=$(free -m | awk '/Swap/{print $2}'); SWU=$(free -m | awk '/Swap/{print $3}')
  [ "${SWT:-0}" -gt 0 ] && [ $(( ${SWU:-0} * 100 / SWT )) -ge 50 ] && flag "MEMORY" "${SWU} MB of ${SWT} MB swap in use"
  MEMAVAIL=$(memavail)
  [ "${MEMAVAIL:-9999}" -lt 500 ] && { flag "MEMORY" "Only ${MEMAVAIL} MB MemAvailable"; prob "only ${MEMAVAIL} MB memory available"; }
  oom=$( (journalctl -k --since "-7 days" --no-pager 2>/dev/null; zgrep -ahiE "out of memory|oom-kill|killed process" /var/log/syslog* 2>/dev/null) | grep -ciE "out of memory|oom-kill|killed process")
  if [ "${oom:-0}" -gt 0 ]; then prob "$oom OOM-kill lines in the last 7 days"; flag "MEMORY" "OOM kills in the last 7 days"; else good "no OOM kills in the last 7 days"; fi
  echo "  recent OOM in dmesg:"; dmesg -T 2>/dev/null | grep -E 'Out of memory|oom-kill:' | grep -E 'Killed process|Out of memory' | tail -5 | sed 's/^/    /' || echo "    none"
  vm=$(vmstat 1 4 2>/dev/null | tail -3 | awk '{us+=$13;sy+=$14;id+=$15;wa+=$16;st+=$17;si+=$7;so+=$8} END{printf "us=%.0f sy=%.0f idle=%.0f iowait=%.0f steal=%.0f si=%d so=%d",us/NR,sy/NR,id/NR,wa/NR,st/NR,si,so}')
  echo "  cpu over ~3 s (percent): $vm"
  [ "$(echo "$vm" | sed -n 's/.*iowait=\([0-9]*\).*/\1/p')" -ge 10 ] 2>/dev/null && { warn "iowait is 10% or more"; flag "MEMORY" "CPU iowait high"; }
  [ "$(echo "$vm" | sed -n 's/.*steal=\([0-9]*\).*/\1/p')" -ge 5 ] 2>/dev/null && { warn "CPU steal is 5% or more"; flag "LOAD" "CPU steal high"; }
  SI=$(echo "$vm" | sed -n 's/.*si=\([0-9]*\).*/\1/p'); SO=$(echo "$vm" | sed -n 's/.*so=\([0-9]*\).*/\1/p')
  [ $(( ${SI:-0} + ${SO:-0} )) -gt 500 ] && flag "MEMORY" "Swap traffic si/so ${SI}/${SO} KB/s"
  echo "  kernel stall pressure (avg10 / avg60 / avg300 %):"
  for r in cpu memory io; do
    line=$(grep '^some' /proc/pressure/$r 2>/dev/null) || continue
    echo "    $r: $(echo "$line" | sed -E 's/^some //; s/ total=.*//')"
    a3=$(echo "$line" | sed -E 's/.*avg300=([0-9.]+).*/\1/')
    [ "$r" != cpu ] && gt "$a3" 3 && flag "MEMORY" "Kernel $r pressure avg300=${a3}%"
  done
  [ ! -r /proc/pressure/memory ] && echo "    (kernel does not expose pressure stall info)"
}

sec_stack() {
  sec "2. STACK AND REQUEST PATH (declared: $STACK)"
  local det=nginx V
  { [ -f /etc/apache2/sites-available/"$APP".conf ] || [ -f /etc/apache2/sites-enabled/"$APP".conf ]; } && det=hybrid
  echo "  detected from Apache vhost presence: $det"
  [ "$det" != "$STACK" ] && warn "declared stack is $STACK but the server looks like $det"
  echo "  listeners (port process):"
  ss -ltnpH 2>/dev/null | awk '{p=$4; sub(/.*:/,"",p); n=$NF; sub(/.*\(\("/,"",n); sub(/".*/,"",n); print p, n}' | grep -E '^(80|443|8080|8081|8082|8084|8085) ' | sort -u | sed 's/^/    /'
  echo "  nginx vhost upstreams:"
  grep -hE "proxy_pass|fastcgi_pass" /etc/nginx/sites-available/"$APP" 2>/dev/null | sed 's/^ */    /' | sort -u
  V=$(dirname "$APPDIR")/conf/custom-recv.vcl
  if [ -s "$V" ]; then
    echo "  app-level Varnish exclusions (custom-recv.vcl):"; head -12 "$V" | sed 's/^/    /'
    if grep -qE 'req\.url ~ "(/|/\*|\.\*)"' "$V"; then warn "a Varnish exclusion matches every URL (Varnish effectively off)"; fi
  else info "no app-level Varnish exclusions"; fi
  [ "$STACK" = nginx ] && info "nginx stack: no Apache hop; Varnish may still sit in front"
}

sec_fpm() {
  sec "3. PHP-FPM"
  if [ -z "$POOL" ]; then skip "no PHP-FPM socket found for $APP"; return; fi
  echo "  pool=$POOL php=$PHPV socket=$SOCK"
  echo "  workers now: $(pgrep -fc "php-fpm: pool $POOL")"
  ps -eo lstart=,args= | grep '[p]hp-fpm: master' | sed 's/^/  master started: /' | cut -c1-110
  local cfg; cfg=$(php-fpm"$PHPV" -tt 2>&1 | awk -v p="[pool $POOL]" 'index($0,p){c=1;next} /\[pool /{c=0} c && /(pm|request_)/{sub(/^\[[^]]*\] NOTICE: */,""); gsub(/^[ \t]+/,""); print}')
  echo "  effective pool settings:"; printf '%s\n' "$cfg" | sed 's/^/    /'
  local mc rss FB MAXCH MC MEMAVAIL NEED RA RN RL
  mc=$(printf '%s\n' "$cfg" | sed -n 's/^pm.max_children *= *//p' | head -1)
  rss=$(ps -eo rss=,args= | awk -v p="pool $POOL" 'index($0,p){s+=$1;n++} END{if(n)printf "%d",s/n/1024}')
  if [ -n "$mc" ] && [ -n "$rss" ]; then
    echo "  pm.max_children=$mc, average worker RSS about ${rss} MB"
    [ "$mc" -lt 20 ] && warn "pm.max_children is $mc, low for a busy site"
    [ $(( mc * rss )) -gt $(( MEMTOTAL * 2 )) ] && info "max_children x RSS = $(( mc * rss )) MB, above twice total RAM if all run"
  fi
  printf '%s\n' "$cfg" | grep -qE '^request_terminate_timeout *= *0' && info "request_terminate_timeout is 0: hung outside calls are never cut off"
  local cz=/etc/php.confs/fpm/extras/cw_customization.conf
  [ -f "$cz" ] && echo "  server-wide customization: $(stat -c '%y' "$cz" | cut -c1-19) $(grep -E '^pm\.max_children' "$cz" | tr -d ' ')"
  local br; br=$(zgrep -ahiE "reached (pm\.)?max_children" /var/log/php*fpm.log* 2>/dev/null | grep -- "$POOL" | wc -l)
  if [ "$br" -gt 0 ]; then
    prob "pool hit pm.max_children $br time(s) in retained logs"
    flag "QUEUE" "pool reached pm.max_children $br time(s)"
    echo "  by hour (current log):"; grep "pool $POOL.*max_children" /var/log/php${PHPV}-fpm.log 2>/dev/null | sed -E 's/^\[([^ ]+) ([0-9]{2}):.*/\1 \2h/' | sort | uniq -c | tail -8 | sed 's/^/    /'
  else good "no pm.max_children breaches in retained FPM logs"; fi
  FB="php-fpm$PHPV"
  if command -v "$FB" >/dev/null 2>&1; then
    $FB -m 2>/dev/null | grep -qix "Zend OPcache" || { flag "PHP" "OPcache not loaded in PHP $PHPV FPM"; warn "OPcache not loaded in FPM"; }
  fi
  RL=$(for i in 1 2 3 4 5; do ps -u "$APP" -o rss=,args= 2>/dev/null | awk '/php-fpm: pool/{printf "%d\n",$1/1024}'; sleep 0.5; done | sort -n)
  RN=$(echo "$RL" | grep -c .); RA=""
  [ "$RN" -gt 0 ] && RA=$(echo "$RL" | awk -v n="$RN" 'BEGIN{i=int(n*0.75); if(i<1)i=1} NR==i{print; exit}')
  MEMAVAIL=$(memavail); MAXCH=$mc
  echo "  worker memory sample: workers=$RN p75 RSS ${RA:-?} MB, max_children ${MAXCH:-?}, MemAvailable ${MEMAVAIL} MB"
  if [ -n "$RA" ] && [ -n "$MAXCH" ] && [ "$RA" -gt 0 ]; then
    NEED=$(( RA * MAXCH ))
    [ "$NEED" -gt "$MEMAVAIL" ] && flag "MEMORY" "All $MAXCH workers at ${RA} MB could need ${NEED} MB vs ${MEMAVAIL} MB available"
  fi
  local sl=$LOGDIR/php-app.slow.log
  if [ -f "$sl" ]; then
    local sn; sn=$(grep -c '^script_filename\|\[pool ' "$sl" 2>/dev/null | head -1)
    sn=$(grep -cE '^script_filename|^\[pool ' "$sl")
    echo "  PHP slow-log entries: $sn"
    if [ "$sn" -gt 0 ]; then
      echo "  plugins/themes in slow traces:"; grep -oE 'wp-content/(plugins|mu-plugins|themes)/[^/]+' "$sl" | sort | uniq -c | sort -rn | head -8 | sed 's/^/    /'
      [ "$sn" -ge 20 ] && warn "$sn slow-log entries"
    fi
  fi
}

sec_opcache() {
  sec "4. OPCACHE AND PHP RUNTIME"
  if [ -z "$SOCK" ] || ! command -v python3 >/dev/null; then skip "needs the FPM socket and python3"; return; fi
  local o; o=$(python3 "$TMP/fcgi.py" php "$SOCK" "$TMP/opc.php" 2>&1)
  if ! printf '%s\n' "$o" | grep -q '^used_mb='; then skip "OPcache probe failed ($(printf '%s' "$o" | head -c 160))"; return; fi
  printf '%s\n' "$o" | sed 's/^/    /'
  local used limit; used=$(kv "$o" used_mb); limit=$(kv "$o" limit_mb)
  [ "$(kv "$o" cache_full)" = true ] && prob "OPcache is full"
  [ "$(kv "$o" oom_restarts)" != 0 ] && warn "OPcache OOM restarts: $(kv "$o" oom_restarts)"
  if [ "${limit:-0}" -gt 0 ]; then
    if awk -v u="$used" -v l="$limit" 'BEGIN{exit !(u/l>=0.95)}'; then prob "OPcache is ${used}/${limit} MB used (95%+)"
    elif awk -v u="$used" -v l="$limit" 'BEGIN{exit !(u/l>=0.85)}'; then warn "OPcache is ${used}/${limit} MB used (85%+); shared by all apps"
    else good "OPcache ${used}/${limit} MB used"; fi
  fi
  num_gt 99 "$(kv "$o" hit_rate)" && warn "OPcache hit rate is $(kv "$o" hit_rate)%"
  [ "$(kv "$o" xdebug)" = 1 ] && { prob "Xdebug is loaded in PHP-FPM"; flag "PHP" "Xdebug loaded"; }
  [ "$(kv "$o" newrelic)" = 1 ] && info "New Relic extension loaded"
  [ "$(kv "$o" i360)" = 1 ] && info "Imunify360 PHP extension (i360) loaded"
  [ "$(kv "$o" revalidate_freq)" = 0 ] && [ "$(kv "$o" validate_timestamps)" = true ] && warn "opcache.revalidate_freq=0 with timestamp validation"
}

sec_db() {
  sec "5. DATABASE ($DBN)"
  command -v mysql >/dev/null || { skip "mysql client not found"; return; }
  [ "$(mysql -N -B -e 'SELECT 1' 2>/dev/null)" = 1 ] || { skip "cannot log in to MySQL as root"; return; }
  local k v reads reqs hit
  declare -A S V
  while IFS=$'\t' read -r k v; do S[$k]=$v; done < <(mysql -N -B -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Uptime','Threads_running','Threads_connected','Max_used_connections','Slow_queries','Aborted_connects','Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests','Created_tmp_tables','Created_tmp_disk_tables','Select_full_join')" 2>/dev/null)
  while IFS=$'\t' read -r k v; do V[$k]=$v; done < <(mysql -N -B -e "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('max_connections','innodb_buffer_pool_size','slow_query_log','long_query_time')" 2>/dev/null)
  echo "  uptime=${S[Uptime]:-?}s threads_running=${S[Threads_running]:-?} connected=${S[Threads_connected]:-?} max_used=${S[Max_used_connections]:-?}/${V[max_connections]:-?} slow_queries=${S[Slow_queries]:-?} aborted_connects=${S[Aborted_connects]:-?}"
  reads=${S[Innodb_buffer_pool_reads]:-0}; reqs=${S[Innodb_buffer_pool_read_requests]:-0}
  hit=$(awk -v r="$reads" -v q="$reqs" 'BEGIN{printf "%.3f",(q>0)?100*(1-r/q):100}')
  echo "  buffer pool: size=$(( ${V[innodb_buffer_pool_size]:-0} / 1048576 ))MB hit rate=${hit}%"
  awk -v r="$reads" -v q="$reqs" 'BEGIN{exit !(q>0 && 100*r/q>1)}' && {
    flag "DB" "More than 1% of InnoDB reads go to disk"
    warn "InnoDB buffer pool disk-read share >1% (hit ${hit}%)"
  }
  num_gt 99 "$hit" && warn "InnoDB buffer pool hit rate is ${hit}%"
  [ "${S[Threads_running]:-0}" -ge 8 ] && { flag "DB" "${S[Threads_running]} MariaDB threads running"; warn "threads_running=${S[Threads_running]}"; }
  local tt=${S[Created_tmp_tables]:-0} td=${S[Created_tmp_disk_tables]:-0}
  [ "$tt" -gt 1000 ] && awk -v d="$td" -v t="$tt" 'BEGIN{exit !(d/t>0.25)}' && warn "$td of $tt temporary tables went to disk"
  [ "${S[Max_used_connections]:-0}" -gt 0 ] && awk -v u="${S[Max_used_connections]:-0}" -v m="${V[max_connections]:-1}" 'BEGIN{exit !(u/m>0.8)}' && warn "connection use peaked above 80% of max_connections"
  local size; size=$(mysql -N -B -e "SELECT ROUND(SUM(data_length+index_length)/1048576) FROM information_schema.tables WHERE table_schema='$DBN'" 2>/dev/null)
  echo "  database size: ${size:-?} MB; largest tables:"
  mysql -N -B -e "SELECT table_name, ROUND((data_length+index_length)/1048576), table_rows FROM information_schema.tables WHERE table_schema='$DBN' ORDER BY (data_length+index_length) DESC LIMIT 5" 2>/dev/null | awk -F'\t' '{printf "    %-45s %6s MB  ~%s rows\n",$1,$2,$3}'
  if [ -n "$PREFIX" ]; then
    local al tr cr auto
    al=$(mysql -N -B -D "$DBN" -e "SELECT COUNT(*), ROUND(SUM(LENGTH(option_value))/1048576,2) FROM ${PREFIX}options WHERE autoload IN ('yes','on','auto','auto-on')" 2>/dev/null)
    echo "  autoloaded options (rows, MB): $al"
    auto=$(echo "$al" | awk '{print $2}')
    num_gt "${auto:-0}" 3 && { prob "autoloaded options are over 3 MB"; flag "PHP" "Autoloaded options ${auto} MB"; }
    num_gt "${auto:-0}" 1 && ! num_gt "${auto:-0}" 3 && { warn "autoloaded options are over 1 MB"; flag "PHP" "Autoloaded options ${auto} MB"; }
    tr=$(mysql -N -B -D "$DBN" -e "SELECT COUNT(*) FROM ${PREFIX}options WHERE option_name LIKE '\\_transient\\_%'" 2>/dev/null)
    [ "${tr:-0}" -gt 5000 ] && warn "$tr transient rows in options table"
    cr=$(mysql -N -B -D "$DBN" -e "SELECT ROUND(LENGTH(option_value)/1024) FROM ${PREFIX}options WHERE option_name='cron'" 2>/dev/null)
    echo "  transients=${tr:-?} cron option=${cr:-?} KB"
    [ "${cr:-0}" -gt 100 ] && warn "the cron option is ${cr} KB (cron backlog)"
  fi
}

sec_app() {
  sec "6. WORDPRESS APPLICATION"
  if [ -z "$MASTER" ] || ! command -v wp >/dev/null; then skip "wp-cli or the master user is not available"; return; fi
  local o; o=$(WP eval-file "$TMP/app.php")
  if ! printf '%s\n' "$o" | grep -q '^wp='; then skip "wp eval-file failed (broken site or fatal error?)"; return; fi
  echo "  WordPress $(kv "$o" wp), home=$(kv "$o" home), active plugins: $(kv "$o" plugin_count)"
  echo "  active theme: $(kv "$o" theme_name) [$(kv "$o" theme)] parent=$(kv "$o" theme_parent)"
  echo "  plugins: $(kv "$o" plugins)" | fold -s -w 150 | sed '2,$s/^/    /'
  echo "  mu-plugins: $(kv "$o" mu_plugins)"
  echo "  drop-ins: object-cache=$(kv "$o" dropin_object_cache) advanced-cache=$(kv "$o" dropin_advanced_cache) WP_CACHE=$(kv "$o" wp_cache)"
  [ "$(kv "$o" wp_debug)" = 1 ] && warn "WP_DEBUG is on in production"
  echo "  cron: disable_wp_cron=$(kv "$o" disable_wp_cron) events=$(kv "$o" cron_events) overdue(10 min)=$(kv "$o" cron_overdue)"
  [ "$(kv "$o" disable_wp_cron)" != 1 ] && { flag "LOAD" "WP-Cron runs on page loads"; warn "WP-Cron runs on visitor page loads"; }
  [ "$(kv "$o" cron_overdue)" -gt 20 ] && warn "$(kv "$o" cron_overdue) cron events overdue >10 min"
  local cnt; cnt=$(kv "$o" plugin_count); [ "${cnt:-0}" -gt 60 ] && info "$cnt active plugins: bootstrap cost likely high"
  local cfg=$APPDIR/wp-config.php
  echo "  wp-config object cache / cache lines (secrets filtered):"
  grep -nE "WP_REDIS|OBJECTCACHE|'database'|'prefix'|WP_CACHE|DISABLE_WP_CRON|WP_ENVIRONMENT_TYPE" "$cfg" 2>/dev/null | grep -viE "token|pass|salt|license" | sed 's/^/    /'
  local mine others
  mine=$(grep -hoP "'database'\s*=>\s*['\"]\K[0-9]+" "$cfg" | head -1)"|"$(grep -hoP "'prefix'\s*=>\s*['\"]\K[^'\"]+" "$cfg" | head -1)
  others=0
  if [ "$mine" != "|" ]; then for f in /home/*.cloudwaysapps.com/*/public_html/wp-config.php; do
    [ "$f" = "$cfg" ] && continue
    [ "$(grep -hoP "'database'\s*=>\s*['\"]\K[0-9]+" "$f" | head -1)|$(grep -hoP "'prefix'\s*=>\s*['\"]\K[^'\"]+" "$f" | head -1)" = "$mine" ] && { others=$((others+1)); echo "    same Redis database and prefix as: $f"; }
  done; fi
  if [ "$mine" != "|" ]; then
    if [ "$others" -gt 0 ]; then prob "another app shares this Redis database and prefix"; else good "Redis database/prefix ($mine) is unique on this server"; fi
  fi
  if [ "$(kv "$o" dropin_object_cache)" = 1 ]; then
    echo "  object cache status:"; WP redis status 2>/dev/null | grep -viE "token|license" | head -14 | sed 's/^/    /' || info "object-cache drop-in present (wp redis status unavailable)"
  else
    echo "  object cache drop-in: none"
    info "no object-cache.php drop-in (Redis/Memcached not wired for WP)"
  fi
  # stash for plugin section
  printf '%s\n' "$o" > "$TMP/app_kv"
}

sec_plugins_themes() {
  sec "7. PLUGINS, THEMES AND KNOWN HEAVY STACKS"
  if [ ! -s "$TMP/app_kv" ]; then
    if [ -z "$MASTER" ] || ! command -v wp >/dev/null; then skip "needs wp-cli from section 6"; return; fi
    WP eval-file "$TMP/app.php" > "$TMP/app_kv" 2>/dev/null || true
  fi
  local o plugins theme parent
  o=$(cat "$TMP/app_kv" 2>/dev/null)
  plugins=$(kv "$o" plugins); theme=$(kv "$o" theme); parent=$(kv "$o" theme_parent)
  echo "  scanning active plugins for known TTFB / load patterns..."
  local hit=0 p
  # Known heavy / chatty patterns (slug substring match)
  for p in \
    "elementor:page builder bootstrap on every front request" \
    "elementor-pro:pro widgets and theme builder on front" \
    "js_composer:WPBakery page builder" \
    "divi-builder:Divi builder assets/shortcodes" \
    "oxygen:Oxygen builder" \
    "beaver-builder:Beaver Builder" \
    "woocommerce:storefront PHP on uncached shop/cart/checkout" \
    "easy-digital-downloads:EDD storefront PHP" \
    "buddyboss-platform:BuddyBoss social features + presence polling" \
    "buddypress:BuddyPress members/activity" \
    "learndash:LearnDash course/quiz PHP" \
    "sensei-lms:Sensei LMS" \
    "memberpress:MemberPress gated content / sessions" \
    "restrict-content:membership gating" \
    "wordfence:Wordfence scan/firewall PHP hooks" \
    "sucuri:Sucuri security hooks" \
    "better-wp-security:iThemes/Solid Security" \
    "all-in-one-wp-security:AIOWPS hooks" \
    "query-monitor:Query Monitor (dev) on production" \
    "debug-bar:Debug Bar on production" \
    "newrelic:New Relic browser/PHP agent side effects" \
    "jetpack:Jetpack modules / sync" \
    "site-kit:Google Site Kit remote calls" \
    "google-site-kit:Google Site Kit" \
    "monsterinsights:analytics remote" \
    "exactmetrics:analytics remote" \
    "wordfence-login:login security" \
    "wp-rocket:page cache / optimizations (confirm exclusions)" \
    "w3-total-cache:W3TC" \
    "litespeed-cache:LiteSpeed cache on non-LS stack" \
    "autoptimize:Autoptimize" \
    "sg-cachepress:SiteGround optimizer leftover?" \
    "redis-cache:Redis Object Cache plugin" \
    "wp-redis:WP Redis" \
    "object-cache-pro:Object Cache Pro" \
    "action-scheduler:Action Scheduler queue (Woo/Mailchimp)" \
    "mailchimp:Mailchimp sync/webhooks" \
    "klaviyo:Klaviyo tracking/API" \
    "hubspot:HubSpot forms/tracking" \
    "intercom:Intercom" \
    "livechat:LiveChat widgets/API" \
    "tawkto:Tawk.to" \
    "crisp:Crisp chat" \
    "wp-cron:N/A" \
    "broken-link-checker:Broken Link Checker crawls" \
    "updraftplus:backup plugin active during traffic" \
    "backupbuddy:backup plugin" \
    "duplicator:migration/backup" \
    "revslider:Slider Revolution" \
    "layerslider:LayerSlider" \
    "wpml-string:WPML string sync" \
    "sitepress-multilingual:WPML" \
    "polylang:Polylang" \
    "yoast-seo:Yoast SEO" \
    "wordpress-seo:Yoast SEO" \
    "rank-math:Rank Math" \
    "redirection:Redirection plugin (rules on every request)" \
    "safe-redirect-manager:redirect rules" \
    "wp-optimize:WP-Optimize" \
    "smush:Smush" \
    "imagify:Imagify" \
    "shortpixel:ShortPixel" \
    "ewww:EWWW Image Optimizer" \
    "webp:WebP converters" \
    "amp:AMP plugin" \
    "pwa:PWA" \
    "push-notification:push plugins" \
    "onesignal:OneSignal" \
    "matomo:Matomo tracking" \
    "piwik:Piwik/Matomo" \
    "facebook-for-woocommerce:Meta pixel / CAPI" \
    "tiktok-for-business:TikTok pixel" \
    "google-listings:Google Listings API" \
  ; do
    local slug="${p%%:*}" msg="${p#*:}"
    echo "$plugins" | grep -qiE "(^|,)${slug}(,|$)" || continue
    echo "    [active] $slug — $msg"
    hit=$((hit+1))
    case "$slug" in
      query-monitor|debug-bar) warn "$slug is active on production (extra per-request cost)"; flag "PHP" "$slug active on production";;
      wordfence|sucuri|better-wp-security|all-in-one-wp-security) info "$slug security plugin active (can add request overhead)";;
      elementor|elementor-pro|js_composer|divi-builder|oxygen|beaver-builder) info "page builder $slug active (front bootstrap cost on uncached pages)";;
      buddyboss-platform|buddypress|learndash|memberpress|woocommerce|easy-digital-downloads)
        info "$slug tends to make many pages uncacheable or PHP-heavy when logged in / carted"
        flag "PHP" "$slug in the stack (uncacheable / heavy request paths likely)"
        ;;
      broken-link-checker|updraftplus|backupbuddy|duplicator) warn "$slug can create background load while active"; flag "LOAD" "$slug can create background load";;
      litespeed-cache) warn "LiteSpeed Cache plugin on a Cloudways (non-LS) stack — confirm it is not fighting Varnish";;
      site-kit|google-site-kit|monsterinsights|klaviyo|hubspot|intercom|livechat|tawkto|crisp|facebook-for-woocommerce|tiktok-for-business)
        info "$slug often makes outside HTTP calls from PHP"
        ;;
    esac
  done
  [ "$hit" -eq 0 ] && echo "    (no entries from the known-heavy list matched; that does not mean the stack is light)"
  echo "  theme cues:"
  case "$theme|$parent" in
    *divi*|*Divi*|*"extra"*) info "Divi/Extra theme family (builder + dynamic CSS cost on uncached pages)";;
    *avada*|*Avada*|*fusion*) info "Avada/Fusion theme family";;
    *flatsome*|*Flatsome*) info "Flatsome (Woo-oriented) theme";;
    *woodmart*|*Woodmart*) info "Woodmart (Woo + AJAX fragments common)";;
    *buddyboss*|*BuddyBoss*) info "BuddyBoss theme (pairs with social platform AJAX)";;
    *hello-elementor*) info "Hello Elementor (Elementor owns the layout)";;
  esac
  # Plugin file counts / sizes (cheap signal of fat plugins)
  if [ -d "$APPDIR/wp-content/plugins" ]; then
    echo "  largest installed plugin directories (disk, not necessarily active):"
    du -sm "$APPDIR"/wp-content/plugins/*/ 2>/dev/null | sort -rn | head -8 | awk '{printf "    %6s MB  %s\n",$1,$2}' | sed "s|$APPDIR/wp-content/plugins/||"
  fi
  if [ -d "$APPDIR/wp-content/themes" ]; then
    echo "  theme directories:"
    du -sm "$APPDIR"/wp-content/themes/*/ 2>/dev/null | sort -rn | head -6 | awk '{printf "    %6s MB  %s\n",$1,$2}' | sed "s|$APPDIR/wp-content/themes/||"
  fi
  # Heartbeat / autosave clutter in code (best-effort)
  if [ -f "$APPDIR/wp-config.php" ]; then
    grep -nE "WP_HEARTBEAT|heartbeat_settings|AUTOSAVE_INTERVAL" "$APPDIR/wp-config.php" 2>/dev/null | sed 's/^/    wp-config: /' || true
  fi
}

sec_logs() {
  sec "8. ACCESS AND ERROR LOGS"
  local AL; AL=$(ls -t "$LOGDIR"/backend_*access.log 2>/dev/null | head -1)
  if [ -z "$AL" ]; then skip "no backend access log in $LOGDIR"; else
    local total; total=$(wc -l < "$AL"); echo "  $AL: $total requests, from $(head -1 "$AL" | awk '{print substr($4,2)}') to $(tail -1 "$AL" | awk '{print substr($4,2)}')"
    if [ "$total" -gt 0 ]; then
      echo "  status codes:"; awk -F'"' '{split($3,s," "); print s[1]}' "$AL" | sort | uniq -c | sort -rn | head -6 | sed 's/^/    /'
      echo "  top IPs:"; awk '{print $1}' "$AL" | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'
      echo "  top URLs (query strings removed):"; awk -F'"' '{split($2,r," "); p=r[2]; sub(/\?.*/,"",p); print p}' "$AL" | sort | uniq -c | sort -rn | head -8 | sed 's/^/    /'
      echo "  peak minutes:"; awk '{print substr($4,2,17)}' "$AL" | sort | uniq -c | sort -rn | head -3 | sed 's/^/    /'
      local ajax rest xmlrpc loginpost bots selfn selfips
      ajax=$(grep -c 'admin-ajax.php' "$AL"); rest=$(grep -c '/wp-json/' "$AL"); xmlrpc=$(grep -c 'xmlrpc.php' "$AL"); loginpost=$(grep -c 'POST /wp-login.php' "$AL")
      bots=$(grep -ciE 'bot|crawler|spider|bytespider|gptbot|claudebot|semrush|ahrefs' "$AL")
      echo "  admin-ajax=$ajax wp-json=$rest xmlrpc=$xmlrpc wp-login POSTs=$loginpost bot-like UAs=$bots"
      [ "$xmlrpc" -gt 100 ] && warn "$xmlrpc requests to xmlrpc.php"
      [ "$loginpost" -gt 200 ] && warn "$loginpost login POSTs in this log"
      awk -v a="$ajax" -v t="$total" 'BEGIN{exit !(a/t>0.3)}' && { warn "admin-ajax is over 30% of requests"; flag "LOAD" "admin-ajax >30% of backend requests"; }
      awk -v a="$rest" -v t="$total" 'BEGIN{exit !(a/t>0.3)}' && warn "REST API calls are over 30% of requests"
      # Cache-busting query strings
      local bust; bust=$(awk -F'[? ]' '/gclid=|utm_|fbclid=|mc_|vero_|_ga=|nocache|nowprocket|cf_cache/{c++} END{print c+0}' "$AL")
      echo "  requests with common cache-busting query params: $bust"
      [ "$bust" -gt 50 ] && awk -v b="$bust" -v t="$total" 'BEGIN{exit !(b/t>0.15)}' && {
        warn "cache-busting query strings appear often ($bust)"
        flag "CACHE" "Many requests carry cache-busting query strings (gclid/utm/fbclid/...)"
      }
      selfips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]' | tr '\n' '|' | sed 's/|$//')
      if [ -n "$selfips" ]; then
        selfn=$(awk '{print $1}' "$AL" | grep -cE "^($selfips|127\.0\.0\.1)\$")
        echo "  requests from this server itself: $selfn"
        awk -v s="$selfn" -v t="$total" 'BEGIN{exit !(s/t>0.3)}' && info "over 30% of logged requests come from the server itself"
      fi
      local top C IP SH is_self=0
      top=$(awk '{print $1}' "$AL" | sort | uniq -c | sort -rn | head -1)
      C=$(echo "$top" | awk '{print $1}'); IP=$(echo "$top" | awk '{print $2}')
      if [ "${total:-0}" -gt 200 ] && [ -n "$C" ]; then
        SH=$(( C * 100 / total ))
        if [ "$SH" -ge 30 ]; then
          for s in $(hostname -I); do [ "$s" = "$IP" ] && is_self=1; done
          [ "$IP" = "127.0.0.1" ] && is_self=1
          if [ "$is_self" = 0 ]; then
            flag "LOAD" "One client address ($IP) made ${SH}% of requests in the current access log"
            info "top IP $IP is ${SH}% of backend requests"
          fi
        fi
      fi
      echo "  status 499 and 5xx:"; awk '{print $9}' "$AL" | grep -E '^(499|5[0-9][0-9])$' | sort | uniq -c | sed 's/^/    /' || echo "    none"
    fi
  fi
  local EL; EL=$(ls -t "$LOGDIR"/backend_*error.log 2>/dev/null | head -1)
  if [ -n "$EL" ]; then
    local sz; sz=$(du -m "$EL" | cut -f1); echo "  error log: $EL ($sz MB)"
    tail -n 3000 "$EL" | sed -E 's/\[[^]]*\]//; s/[0-9]+/N/g' | cut -c1-150 | sort | uniq -c | sort -rn | head -4 | sed 's/^/    /'
    [ "$sz" -gt 50 ] && warn "error log is ${sz} MB (noisy plugin or PHP deprecations)"
  fi
}

sec_ttfb_anatomy() {
  sec "9. TTFB ANATOMY (warm / cold / origin)"
  echo "  urls: $ALLURLS"
  echo "  samples per series: $N   UA: ${UA:0:48}...   front-ip: ${FRONTIP:-none}"
  echo "  (server wait = ttfb minus connection setup; if never a cache HIT, every visit pays the cold cost)"
  local U hdr code loc
  hdr=$(curl -sk -A "$UA" -D - -o /dev/null --max-time 20 "$BASE/" 2>/dev/null | tr -d '\r')
  echo "  response headers for $BASE/ :"
  printf '%s\n' "$hdr" | grep -iE '^(HTTP|location|server|cf-ray|cf-cache-status|x-cache|via|x-varnish|cache-control|content-length|age)' | sed 's/^/    /'
  printf '%s\n' "$hdr" | grep -qiE '^(cf-ray|server: cloudflare)' && info "Cloudflare is in front of this site" || info "no CDN headers seen on / (visitors may connect straight to the server)"
  code=$(printf '%s\n' "$hdr" | head -1 | awk '{print $2}')
  loc=$(printf '%s\n' "$hdr" | sed -n 's/^[Ll]ocation: //p' | head -1)
  if [ "$code" = 302 ] && printf '%s' "$loc" | grep -q 'wp-login'; then
    info "/ redirects to login (members-only): not page-cacheable; every visit costs PHP twice"
  fi
  if [ "$code" = 302 ] && printf '%s\n' "$hdr" | grep -qi '^content-length: 0'; then
    info "/ returns empty-body 302 (relevant to Varnish identical-request queueing on hybrid)"
  fi
  for U in $ALLURLS; do test_url_anatomy "$U"; done
  # Keep sitecheck-style origin average for concurrency comparison
  local first=${PATHS%% *}
  [ -z "$first" ] && first="/"
  sample "origin direct $first (127.0.0.1)" "$BASE$first" "$N" --resolve "$DOMAIN:443:127.0.0.1"
  ORIGIN_AVG=$LAST_AVG
  if [ "$STACK" = hybrid ]; then
    echo "  hybrid layer hops for /wp-login.php (Host header, no CDN):"
    sample "Varnish :8080" "http://127.0.0.1:8080/wp-login.php" 6 -H "Host: $DOMAIN" -H "X-Forwarded-Proto: https"
    sample "Apache  :8081" "http://127.0.0.1:8081/wp-login.php" 6 -H "Host: $DOMAIN" -H "X-Forwarded-Proto: https"
  fi
}

sec_tagged() {
  sec "10. WHERE THE WAIT GOES (tagged probes)"
  [ -n "$FIRST_FINAL" ] || FIRST_FINAL=$(echo "$ALLURLS" | awk '{print $1}')
  tagged_probes "$FIRST_FINAL"
}

sec_php_log() {
  sec "11. PHP LOG: TYPICAL VERSUS STALLED REQUESTS"
  local AFL="$PLOG" S C K
  if [ ! -s "$AFL" ]; then echo "  (php access log missing or empty)"; skip "no php-app.access.log"; return; fi
  echo "  window: $(head -1 "$AFL" | grep -oE '\[[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:[0-9:]{8}' | head -1) to $(tail -1 "$AFL" | grep -oE '\[[0-9]{2}/[A-Za-z]{3}/[0-9]{4}:[0-9:]{8}' | tail -1)"
  awk -F'"' '{split($3,a," "); if(a[6] ~ /^[0-9.]+$/) print a[6]}' "$AFL" > "$TMP/dur"
  echo "  PHP seconds/request: p50 $(pct "$TMP/dur" 1 50)  p90 $(pct "$TMP/dur" 1 90)  p99 $(pct "$TMP/dur" 1 99)  max $(pct "$TMP/dur" 1 100)  over $(wc -l < "$TMP/dur") requests"
  echo "  -- share of PHP time by request type --"
  awk -F'"' '{split($3,a," "); if(a[6] !~ /^[0-9.]+$/) next; p=$4; sub(/\?.*/,"",p); c="front-end"; if(index(p,"admin-ajax.php")) c="admin-ajax"; else if(index(p,"wp-cron.php")) c="wp-cron"; else if(index(p,"/wp-json")==1 || index($4,"rest_route")) c="rest-api"; else if(index(p,"/wp-admin")==1 || index(p,"/wp-login")==1) c="wp-admin/login"; else if(p ~ /\.(ico|txt|png|jpe?g|webp|svg|json|xml|map|css|js|woff2?)$/) c="static-via-php"; t[c]+=a[6]; n[c]++; T+=a[6]} END{for(k in t) printf "%-15s %6d reqs %8.0fs %5.1f%%\n", k, n[k], t[k], (T>0?100*t[k]/T:0)}' "$AFL" | sort -k4 -nr | tee "$TMP/share" | sed 's/^/    /'
  awk '$1!="front-end" && $1!="static-via-php"{gsub("%","",$5); s+=$5} END{exit !(s>=50)}' "$TMP/share" && {
    flag "LOAD" "More than half of PHP time goes to admin-ajax/cron/REST/wp-admin"
    warn "background/admin PHP time dominates visitor front-end time"
  }
  awk '$1=="static-via-php"{gsub("%","",$5); exit !($5>=10)}' "$TMP/share" && {
    flag "PHP" "Static-looking files answered by PHP use >=10% of PHP time"
    warn "missing/static URLs hitting PHP (>=10% of PHP time)"
  }
  echo "  -- stall bursts: requests over 10 s --"
  awk -F'"' 'function key(s){ if(match(s,/[0-9][0-9]\/[A-Za-z][A-Za-z][A-Za-z]\/20[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) return substr(s,RSTART,RLENGTH); return "" }
    NR==FNR{split($3,b," "); if(b[6]+0>10){k=key($1); if(k!=""){m[k]++}} next}
    {split($3,b," "); if(b[6]+0>10){S++; k=key($1); if(k!="" && m[k]>=3) C++}} END{K=0; for(x in m) if(m[x]>=3){K++; print "BURST " x " " m[x]} ; print "SUM " S+0 " " C+0 " " K}' "$AFL" "$AFL" > "$TMP/bursts"
  read -r _ S C K < <(grep '^SUM' "$TMP/bursts")
  echo "  slow >10s: ${S:-0}; inside burst minutes: ${C:-0}; burst minutes: ${K:-0}"
  grep '^BURST' "$TMP/bursts" | sort -k3 -nr | head -6 | sed 's/^BURST /    minute /'
  if [ "${S:-0}" -ge 5 ] && [ "${C:-0}" -gt 0 ] && [ $(( ${C:-0} * 100 / S )) -ge 50 ]; then
    flag "STALL" "${C} of ${S} requests >10s finished in ${K} burst minutes"
    warn "stall-burst pattern in PHP log"
  fi
  echo "  -- top 8 requests by total PHP time --"
  awk -F'"' '{split($3,a," "); if(a[6] !~ /^[0-9.]+$/) next; split($2,r," "); p=$4; sub(/\?.*/,"",p); k=r[1]" "p; n[k]++; t[k]+=a[6]; if(a[6]+0>m[k]) m[k]=a[6]+0} END{for(k in n) printf "%7.0f %5d %6.2f %6.2f  %s\n", t[k], n[k], t[k]/n[k], m[k], k}' "$AFL" | sort -rn | head -8 | sed '1i\    total_s  reqs  avg_s  max_s  request'
}

sec_slowlog() {
  sec "12. PHP SLOW LOG (what PHP was waiting on)"
  local SL="$LOGDIR/php-app.slow.log" T o d f s r a
  if [ ! -s "$SL" ]; then echo "  (no slow log entries)"; return; fi
  T=$(grep -c '^\[0x' "$SL"); echo "  traces: $(grep -c 'pool ' "$SL")  frames: $T"
  awk '/\[pool /{f=1;next} f && /^\[0x/{print $2; f=0}' "$SL" > "$TMP/frames"
  o=$(grep -cE 'curl_exec|file_get_contents|fsockopen|stream_socket|wp_remote|wp_safe_remote|WP_Http' "$TMP/frames")
  d=$(grep -cE 'mysqli|mysql_|query|wpdb' "$TMP/frames")
  r=$(grep -cE 'Redis|redis|hGetAll|hmGet|predis|getWithMeta|Clients' "$TMP/frames")
  f=$(grep -cE 'autoload|load_class|include|require|file_exists|is_readable|readdir|opendir|stat|realpath|scandir|glob' "$TMP/frames")
  s=$(grep -cE 'sleep|usleep' "$TMP/frames"); a=$(wc -l < "$TMP/frames")
  echo "  first blocking frame categories out of $a: outside=$o db=$d redis=$r files=$f sleep=$s"
  echo "  top first frames:"; sort "$TMP/frames" | uniq -c | sort -nr | head -8 | sed 's/^/    /'
  echo "  nearest plugin/theme in each trace:"
  awk '/\[pool /{if(w!="")print w; w=""; next} w=="" && match($0,/wp-content\/(plugins|themes)\/[^\/]+/){w=substr($0,RSTART,RLENGTH)} END{if(w!="")print w}' "$SL" | sort | uniq -c | sort -nr | head -8 | sed 's/^/    /'
  [ "$a" -gt 0 ] && [ $(( o * 100 / a )) -ge 30 ] && { flag "OUTSIDE" "$o of $a slow traces blocked in outside call"; warn "slow log dominated by outside calls"; }
  [ "$a" -gt 0 ] && [ $(( d * 100 / a )) -ge 30 ] && { flag "DB" "$d of $a slow traces blocked in DB"; warn "slow log dominated by DB calls"; }
  [ "$a" -gt 0 ] && [ $(( r * 100 / a )) -ge 30 ] && { flag "DB" "$r of $a slow traces blocked in Redis"; warn "slow log dominated by Redis/object-cache"; }
  [ "$a" -gt 0 ] && [ $(( f * 100 / a )) -ge 30 ] && { flag "MEMORY" "$f of $a slow traces blocked loading PHP files"; warn "slow log dominated by file loading (disk/swap?)"; }
}

sec_conc() {
  sec "13. CONCURRENCY (logged out, ${CONC_DUR}s per step)"
  local why; if ! why=$(safe_to_load); then skip "load tests skipped: $why"; return; fi
  local v0="$TMP/v0" v1="$TMP/v1"; vsnap "$v0"
  local first=${PATHS%% *}; [ -z "$first" ] && first="/"
  conc "same URL  $first" "$BASE$first" 5 "$CONC_DUR"; sleep 2
  conc "same URL  $first" "$BASE$first" 20 "$CONC_DUR"; local same_avg=$LAST_AVG same_p95=$LAST_P95; sleep 2
  conc "unique URL ${first}?sc=" "$BASE$first?sc=@@" 20 "$CONC_DUR"; local uniq_avg=$LAST_AVG; sleep 2
  conc "login page" "$BASE/wp-login.php" 20 "$CONC_DUR"
  vsnap "$v1"
  if [ -s "$v0" ]; then echo "  Varnish counters that changed:"; vdiff "$v0" "$v1" | sed 's/^/    /'; fi
  local bs; bs=$(vdiff "$v0" "$v1" 2>/dev/null | awk '$1=="MAIN.busy_sleep"{print $2}')
  if awk -v a="$same_avg" -v b="$uniq_avg" 'BEGIN{exit !(a>b*3 && a>1)}'; then
    local cause
    if [ "${bs:-0}" -gt 50 ]; then cause="Varnish busy-wait confirmed, busy_sleep rose by $bs"
    elif [ -s "$v0" ]; then cause="Varnish busy_sleep did not rise (+${bs:-0}): look for app-level lock/serialization"
    else cause="cause unconfirmed (no varnishstat)"; fi
    prob "identical requests queue (same ${same_avg}s vs unique ${uniq_avg}s at 20 parallel): $cause"
    flag "QUEUE" "Identical-URL concurrency queues behind uncacheable responses"
  else good "same-URL requests do not queue (same ${same_avg}s vs unique ${uniq_avg}s)"; fi
  [ -n "${ORIGIN_AVG:-}" ] && awk -v u="$uniq_avg" -v o="$ORIGIN_AVG" 'BEGIN{exit !(u>o*4 && u>1.5)}' && warn "unique-URL latency at 20 parallel (${uniq_avg}s) >4x single-request (${ORIGIN_AVG}s)"
  [ "$LAST_BAD" -gt 0 ] && warn "$LAST_BAD 5xx/failed during login-page concurrency"
}

li_login() {
  local j=$1; : > "$j"; chmod 600 "$j"
  curl -sk -A "$UA" -c "$j" -b "$j" -o /dev/null "$BASE/wp-login.php"
  curl -sk -A "$UA" -c "$j" -b "$j" -o /dev/null --data-urlencode "log=$WP_USER" --data-urlencode "pwd=$WP_PASS" -d "wp-submit=Log+In&testcookie=1" "$BASE/wp-login.php"
  grep -q wordpress_logged_in "$j"
}

ramp() {
  local n=$1 stag=$2 dur=$3; shift 3; local paths="$*" out="$TMP/ramp.$n" i pids="" sp gp
  : > "$out"; : > "$TMP/ramp.s"; rm -f "$TMP/abort"
  for i in $(seq 1 "$n"); do li_login "$TMP/rj.$i" || { warn "ramp: login failed for session $i"; return 1; }; done
  local end=$(( $(date +%s) + dur + stag ))
  ( while :; do echo "$(memavail) $(cut -d' ' -f1 /proc/loadavg) $(pgrep -fc "php-fpm: pool $POOL")" >> "$TMP/ramp.s"; sleep 1; done ) & sp=$!
  ( while [ ! -f "$TMP/abort" ]; do [ "$(memavail)" -lt "$MEM_FLOOR" ] && touch "$TMP/abort"; sleep 1; done ) & gp=$!
  for i in $(seq 1 "$n"); do
    ( sleep $(( RANDOM % (stag + 1) )); while [ "$(date +%s)" -lt "$end" ] && [ ! -f "$TMP/abort" ]; do
        for p in $paths; do curl -sk -A "$UA" -b "$TMP/rj.$i" -o /dev/null -w "$p %{http_code} %{time_starttransfer}\n" "$BASE$p" >> "$out"; sleep $(( RANDOM % 3 + 1 )); done
      done ) &
    pids="$pids $!"
  done
  wait $pids; kill $sp $gp 2>/dev/null
  [ -f "$TMP/abort" ] && warn "ramp N=$n stopped early: MemAvailable < ${MEM_FLOOR} MB"
  sort -k3 -n "$out" | awk -v n="$n" '{a[NR]=$3; if($2>=400||$2==0)b++; else if($2>=300)r++} END{i=int(NR*0.95); if(i<1)i=1; printf "  N=%-2d sessions: reqs=%d p50=%.2f p95=%.2f max=%.2f errors=%d redirects=%d\n",n,NR,a[int((NR+1)/2)],a[i],a[NR],b+0,r+0}'
  RAMP_P95=$(sort -k3 -n "$out" | awk '{a[NR]=$3} END{i=int(NR*0.95); if(i<1)i=1; printf "%.2f",a[i]}')
  RAMP_BAD=$(awk '($2>=400||$2==0){b++} END{print b+0}' "$out")
  RAMP_REDIR=$(awk '($2>=300&&$2<400){r++} END{print r+0}' "$out"); RAMP_TOTAL=$(wc -l < "$out")
  awk '{print $1}' "$out" | sort -u | while read -r p; do grep "^$p " "$out" | sort -k3 -n | awk -v p="$p" '{a[NR]=$3} END{i=int(NR*0.95); if(i<1)i=1; printf "      %-40s p50=%.2f p95=%.2f (n=%d)\n",p,a[int((NR+1)/2)],a[i],NR}'; done
  awk 'NR==1{m=$1} {if($1<m)m=$1; if($2>l)l=$2; if($3>f)f=$3} END{printf "      min MemAvailable=%dMB max load1=%.1f max fpm workers=%d\n",m,l,f}' "$TMP/ramp.s"
  RAMP_WORKERS=$(awk '{if($3>f)f=$3} END{print f+0}' "$TMP/ramp.s")
}

sec_loggedin() {
  sec "14. LOGGED-IN TESTS"
  if [ "$LEVEL" = quick ]; then skip "logged-in tests need LEVEL=standard or full"; return; fi
  if [ -z "${WP_USER:-}" ] || [ -z "${WP_PASS:-}" ]; then
    if [ "$LEVEL" = full ]; then WP_USER=$(ask "Test user login (leave empty to skip): "); [ -n "$WP_USER" ] && WP_PASS=$(ask_secret "Password (not echoed, not stored): "); fi
  fi
  if [ -z "${WP_USER:-}" ] || [ -z "${WP_PASS:-}" ]; then skip "no test credentials (set WP_USER/WP_PASS or run LEVEL=full interactively)"; return; fi
  local J="$TMP/jar.main"
  if ! li_login "$J"; then warn "login failed for the test user"; return; fi
  good "test user logged in"
  local p; echo "  logged-in single-request timings (8 each):"
  for p in $LI_PATHS; do sample "logged in $p" "$BASE$p" 8 -b "$J"; LI_FIRST_AVG=${LI_FIRST_AVG:-$LAST_AVG}; done
  local src hb rn
  src=$(curl -sk -A "$UA" -b "$J" "$BASE/")
  hb=$(printf '%s' "$src" | sed -nE 's/.*heartbeatSettings = \{[^}]*"nonce":"([A-Za-z0-9]+)".*/\1/p' | head -1)
  if [ -n "$hb" ]; then
    echo "  heartbeat (admin-ajax) x5:"
    local i; for i in 1 2 3 4 5; do curl -sk -A "$UA" -b "$J" -o /dev/null -X POST --data-urlencode "_nonce=$hb" -d "action=heartbeat&interval=60&screen_id=front&has_focus=true" -w '    code=%{http_code} ttfb=%{time_starttransfer} total=%{time_total}\n' "$BASE/wp-admin/admin-ajax.php"; done
    info "heartbeat total−TTFB is worker time held after first byte"
  fi
  rn=$(printf '%s' "$src" | sed -nE 's/.*rest_nonce\\*":\\*"([A-Za-z0-9]+).*/\1/p' | head -1)
  if printf '%s' "$src" | grep -q 'members/presence' && [ -n "$rn" ]; then
    echo "  BuddyBoss presence x3:"
    local i; for i in 1 2 3; do curl -sk -A "$UA" -b "$J" -o /dev/null -X POST -H "X-WP-Nonce: $rn" -H "Content-Type: application/json" --data '{"ids":[1]}' -w '    code=%{http_code} ttfb=%{time_starttransfer} total=%{time_total}\n' "$BASE/wp-json/buddyboss/v1/members/presence"; done
  fi
  if [ "$LEVEL" = full ] && [ -n "$SOCK" ] && command -v python3 >/dev/null; then
    local first=${LI_PATHS%% *} ck r davg
    ck=$(awk -F'\t' '!/^# / && NF>=7 {sub(/^#HttpOnly_/,"",$1); printf "%s=%s; ",$6,$7}' "$J")
    r=$(SC_COOKIE="$ck" python3 "$TMP/fcgi.py" req "$SOCK" "$APPDIR" "$DOMAIN" "$first" 6 2>&1)
    davg=$(printf '%s\n' "$r" | sed -n 's/.*TIMES //p' | awk '{for(i=2;i<=NF;i++){s+=$i;n++}} END{if(n)printf "%.3f",s/n}')
    if [ -n "$davg" ]; then
      echo "  PHP-FPM direct $first: avg ${davg}s vs public logged-in avg ${LI_FIRST_AVG:-?}s"
      awk -v p="${LI_FIRST_AVG:-0}" -v d="$davg" 'BEGIN{exit !(p-d>0.15)}' && warn "web layers add $(awk -v p="${LI_FIRST_AVG:-0}" -v d="$davg" 'BEGIN{printf "%.2f",p-d}')s in front of PHP"
    else info "FPM-direct did not return timings: $(printf '%s' "$r" | head -c 150)"; fi
  fi
  if [ "$LEVEL" = full ]; then
    local why; if ! why=$(safe_to_load); then skip "ramp skipped: $why"; return; fi
    echo "  logged-in ramp: stagger ${STAG}s, ${RAMP_DUR}s load, pages: $LI_PATHS"
    local n; for n in $RAMP_N; do
      ramp "$n" "$STAG" "$RAMP_DUR" $LI_PATHS
      if num_gt "$RAMP_P95" 4; then prob "logged-in p95 ${RAMP_P95}s with $n sessions"; elif num_gt "$RAMP_P95" 2; then warn "logged-in p95 ${RAMP_P95}s with $n sessions"; fi
      [ "${RAMP_BAD:-0}" -gt 0 ] && warn "$RAMP_BAD error responses with $n sessions"
      [ "${RAMP_TOTAL:-0}" -gt 0 ] && awk -v r="${RAMP_REDIR:-0}" -v t="$RAMP_TOTAL" 'BEGIN{exit !(r/t>0.5)}' && warn "over half of ramp responses were redirects"
      sleep 5
    done
    if [ "${STRACE:-0}" = 1 ] && command -v strace >/dev/null && [ -n "$POOL" ]; then
      echo "  strace (INTRUSIVE, 10 s):"
      local pids; pids=$(pgrep -f "php-fpm: pool $POOL" | sed 's/^/-p /' | tr '\n' ' ')
      ( sleep 1; for i in 1 2 3 4 5; do curl -sk -A "$UA" -b "$J" -o /dev/null "$BASE${LI_PATHS%% *}"; done ) &
      timeout -s INT 10 strace -f -c -w $pids 2>&1 | grep -vE 'attached|detached' | head -14 | sed 's/^/    /'
      wait
    fi
  fi
}

sec_waf_cpu() {
  sec "15. WAF AND WHAT USES THE CPU"
  echo "  Imunify services: $(for s in imunify360-wafd imunify360 imunify-realtime-av; do printf '%s=%s ' "$s" "$(systemctl is-active $s 2>/dev/null)"; done)"
  echo "  ModSecurity directives (recommended files ignored):"
  grep -rnE "^\s*Sec(RuleEngine|ResponseBodyAccess|RequestBodyAccess)\b" /etc/imunify360-wafd/ /etc/modsecurity/ /etc/apache2/ 2>/dev/null | grep -v 'recommended' | cut -c1-140 | sed 's/^/    /'
  grep -rhE "^\s*SecResponseBodyAccess\s+On" /etc/imunify360-wafd/ /etc/modsecurity/ 2>/dev/null | grep -v recommended | grep -q . && warn "ModSecurity response-body inspection is On (can add TTFB)"
  if command -v imunify360-agent >/dev/null 2>&1; then
    local C; C=$(imunify360-agent get --period 1d --limit 500 </dev/null 2>&1 | awk 'NR>1 && /DoS/' | grep -c .)
    echo "  Imunify360 DoS-type incidents (last day): $C"
    [ "$C" -gt 0 ] && { flag "LOAD" "Imunify360 logged $C DoS-type incident(s) in 24h"; warn "Imunify DoS incidents: $C"; }
  fi
  echo "  top CPU consumers over 10 s (% of ONE core; machine = $(( CPUS * 100 ))):"
  top -b -n 2 -d 10 -w 512 2>/dev/null | awk '/^top - /{n++} n==2 && $1 ~ /^[0-9]+$/ {c[$12]+=$9} END{for(k in c) if(c[k]>=5) printf "    %-24s %5.0f%%\n",k,c[k]}' | sort -k2 -nr | head -8
}

sec_neighbours() {
  sec "16. OTHER APPS ON THIS SERVER"
  local d a f
  for d in /home/*.cloudwaysapps.com/*/; do
    a=$(basename "$d"); f="${d}logs/php-app.access.log"; [ -s "$f" ] || continue
    awk -F'"' -v a="$a" -v me="$APP" '{split($3,x," "); if(x[6] !~ /^[0-9.]+$/) next; n++; t+=x[6]; if(x[6]+0>10) s++} END{printf "%-12s %6d reqs %8.0fs %4d over 10s%s\n", a, n+0, t+0, s+0, (a==me?"   <- this app":"")}' "$f"
  done | tee "$TMP/neigh" | sed 's/^/  /'
  awk -v me="$APP" '{t=$3; sub("s","",t); if($1==me) mine=t+0; else o+=t+0} END{exit !(o>mine && o>0)}' "$TMP/neigh" 2>/dev/null && {
    flag "NEIGHBOUR" "Other apps used more PHP time than this app in current logs"
    warn "neighbour apps consume more PHP time than $APP"
  }
}

summary() {
  echo; echo "================================================================"
  echo " FINDINGS SUMMARY  app=$APP db=$DBN domain=$DOMAIN stack=$STACK level=$LEVEL  ($(date -u +%FT%TZ))"
  echo "================================================================"
  local x c n
  if [ -n "$TP_N" ] && [ "$TP_N" -gt 0 ] 2>/dev/null; then
    echo
    echo " WHERE THE TIME GOES (uncached, median of $TP_N matched probes)"
    echo "   ttfb ${TP_TTFB}s | network ${TP_NET}s | before PHP ${TP_BEF}s | inside PHP ${TP_PHP}s"
    awk -v n="$TP_NET" -v b="$TP_BEF" -v p="$TP_PHP" 'BEGIN{
      m=n; w="network (connection setup)"
      if(b+0>m){m=b; w="time before PHP starts (front layers or worker queue)"}
      if(p+0>m){m=p; w="time inside PHP"}
      printf "   largest part: %s\n", w
    }'
  fi
  echo
  echo " INDICATORS BY AREA"
  if [ "${#FLAGS[@]}" -eq 0 ]; then echo "   (none raised)"; else
    for c in CACHE PATH QUEUE PHP DB OUTSIDE MEMORY STALL NEIGHBOUR LOAD TTFB; do
      n=$(printf '%s\n' "${FLAGS[@]}" | awk -F'|' -v c="$c" '$1==c' | wc -l)
      [ "$n" -gt 0 ] && {
        echo " [$c]"
        printf '%s\n' "${FLAGS[@]}" | awk -F'|' -v c="$c" '$1==c && !s[$2]++{print "   - " $2}'
      }
    done
  fi
  echo
  echo " PROBLEMS (${#PROB[@]})"; for x in "${PROB[@]:-}"; do [ -n "$x" ] && echo "   - $x"; done
  echo " WARNINGS (${#WARNS[@]})"; for x in "${WARNS[@]:-}"; do [ -n "$x" ] && echo "   - $x"; done
  echo " NOTES (${#INFOS[@]})"; for x in "${INFOS[@]:-}"; do [ -n "$x" ] && echo "   - $x"; done
  echo " NOT CHECKED (${#SKIPS[@]})"; for x in "${SKIPS[@]:-}"; do [ -n "$x" ] && echo "   - $x"; done
  echo
  echo " Areas: CACHE=not cacheable | PATH=network/CDN/proxy | QUEUE=before PHP | PHP=inside PHP"
  echo "        DB=MariaDB/Redis | OUTSIDE=remote calls | MEMORY=RAM/swap/disk | STALL=server-wide freezes"
  echo "        NEIGHBOUR=other apps | LOAD=background/traffic | TTFB=measured wait/failures"
  echo " Full report: $REPORT"
  echo " Indicators are not proof — confirm against the sections above before telling the customer."
}

main() {
  case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
  get_inputs "$@"
  [ "$(id -u)" = 0 ] || { echo "Run as root (sudo -i)."; exit 1; }
  TMP=$(mktemp -d /tmp/sitecheck.XXXXXX); chmod 755 "$TMP"; umask 077
  trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT
  HF="$TMP/h"
  discover
  SELFRE=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep . | sed 's/\./\\./g' | paste -sd'|')
  resolve_urls
  REPORT=/tmp/sitecheck-$APP-$(date -u +%Y%m%dT%H%M%SZ).txt
  exec > >(tee -a "$REPORT") 2>&1
  CONC_DUR=${CONC_DUR:-12}
  echo "sitecheck $SC_VERSION  app=$APP db=$DBN domain=$DOMAIN stack=$STACK level=$LEVEL"
  echo "  appdir=$APPDIR  logs=$LOGDIR  base=$BASE"
  echo "  urls: $ALLURLS"
  echo "  N=$N PROBES=$PROBES CONC_DUR=$CONC_DUR origin=$ORIGIN_OK sample=$SAMPLE"
  write_helpers
  sec_system
  sec_stack
  sec_fpm
  sec_opcache
  sec_db
  sec_app
  sec_plugins_themes
  sec_logs
  sec_ttfb_anatomy
  sec_tagged
  sec_php_log
  sec_slowlog
  if [ "$LEVEL" != quick ]; then sec_conc; else sec "13. CONCURRENCY"; skip "concurrency tests need LEVEL=standard or full"; fi
  sec_loggedin
  sec_waf_cpu
  sec_neighbours
  summary
  sleep 0.5
}

if [ "${SC_SOURCE_ONLY:-0}" != 1 ]; then main "$@"; fi
