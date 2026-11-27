#!/usr/bin/env bash
# breeze-check.sh - Cloudways read-only Breeze / CSS-combine / Varnish diagnosis
#
# Focus: one-click Advanced (combine CSS) + daily purge leaving Varnish HTML
# that still links to deleted combined CSS (unstyled site the next day).
#
# Usage:
#   bash breeze-check.sh [APP] [quick|standard|full]
#   APP=ngqmfhzzvk LEVEL=full bash breeze-check.sh
#   curl -fsSL "<raw url>/breeze-check.sh" | bash -s -- ngqmfhzzvk full
#
# Levels:
#   quick     settings + disk + cron + edge HTML/CSS status
#   standard  + historical CSS 404s + purge-grace vs Varnish TTL code check
#   full      + dump key Breeze purge/sweep code paths + varnish counters
#
# Optional env: DOMAIN, BASE, URL / PATHS, UA, WP_ALLOW_ROOT=1
# Changes nothing on the app. Report: /tmp/breeze-check-<app>-*.txt
set -u
export LC_ALL=C
BC_VERSION="1.0"

PROB=(); WARNS=(); INFOS=(); SKIPS=(); NOTES=()
APP=${APP:-}; LEVEL=${LEVEL:-}
APPDIR=""; LOGDIR=""; DOMAIN=${DOMAIN:-}; BASE=${BASE:-}
MASTER=""; PREFIX=""; BREEZE=""; REPORT=""
UA=${UA:-'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'}
PATHS=${PATHS:-}; URL=${URL:-}; ALLURLS=""
TMP=""; STARTED=""

prob() { PROB+=("$*"); echo "  [PROBLEM] $*"; }
warn() { WARNS+=("$*"); echo "  [WARN]    $*"; }
info() { INFOS+=("$*"); echo "  [info]    $*"; }
good() { echo "  [ok]      $*"; }
note() { NOTES+=("$*"); echo "  [note]    $*"; }
skip() { SKIPS+=("$*"); echo "  [skipped] $*"; }
sec()  { echo; echo "==== $* ===="; }
ask() { local v=""; if [ -r /dev/tty ]; then read -r -p "$1" v < /dev/tty; fi; echo "$v"; }

usage() { cat << 'EOT'
breeze-check.sh - Breeze CSS-combine / daily purge / Varnish stale-HTML check (read-only)
  bash breeze-check.sh [APP] [quick|standard|full]
  APP=ngqmfhzzvk LEVEL=full bash breeze-check.sh
  curl -fsSL "<raw url>/breeze-check.sh" | bash -s -- ngqmfhzzvk full

LEVEL: quick | standard | full
Optional: DOMAIN, BASE, URL, PATHS, UA
EOT
}

get_inputs() {
  APP=${APP:-${1:-}}; LEVEL=${LEVEL:-${2:-standard}}
  case "${1:-}" in -h|--help|help) usage; exit 0;; esac
  [ -n "$APP" ] || APP=$(ask "Application / DB name (10-letter app folder, e.g. ngqmfhzzvk): ")
  [ -n "$APP" ] || { echo "No application name given."; exit 1; }
  case "$LEVEL" in quick|standard|full) ;; *) echo "LEVEL must be quick, standard or full (got '$LEVEL')."; exit 1 ;; esac
}

discover() {
  APPDIR=$(ls -d /home/*.cloudwaysapps.com/"$APP"/public_html 2>/dev/null | head -1)
  [ -n "$APPDIR" ] || APPDIR=$(find /home -maxdepth 4 -type d -path "*/$APP/public_html" 2>/dev/null | head -1)
  [ -n "$APPDIR" ] || { echo "Cannot find public_html for app '$APP' under /home."; exit 1; }
  LOGDIR=/home/master/applications/$APP/logs
  [ -d "$LOGDIR" ] || LOGDIR=$(dirname "$APPDIR")/logs
  MASTER=$(grep '^master_' /etc/passwd 2>/dev/null | head -1 | cut -d: -f1)
  [ -z "$MASTER" ] && MASTER=$(stat -c %U "$APPDIR" 2>/dev/null || true)
  PREFIX=$(grep -oP "table_prefix\s*=\s*'\K[^']+" "$APPDIR/wp-config.php" 2>/dev/null | head -1)
  PREFIX=${PREFIX:-wp_}
  BREEZE="$APPDIR/wp-content/plugins/breeze"
  if [ -z "${DOMAIN:-}" ]; then
    DOMAIN=$(WP option get home 2>/dev/null | head -1 | sed -E 's#^https?://##; s#/.*##')
  fi
  [ -n "${DOMAIN:-}" ] || DOMAIN=$(grep -h server_name /etc/nginx/sites-available/"$APP" 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';')
  [ -n "${DOMAIN:-}" ] || DOMAIN=$(awk 'NR==1{print substr($NF,1,length($NF)-1)}' /home/master/applications/"$APP"/conf/server.nginx 2>/dev/null)
  [ -n "${DOMAIN:-}" ] || DOMAIN=$(ls "$LOGDIR"/backend_*access.log 2>/dev/null | head -1 | sed -E 's#.*/backend_([^/]+)\.access\.log#\1#')
  [ -n "${DOMAIN:-}" ] || { echo "Cannot detect domain; pass DOMAIN=example.com"; exit 1; }
  if [ -n "${BASE:-}" ]; then :; elif [ -n "${URL:-}" ]; then
    case "$URL" in http://*|https://*) BASE=$(echo "$URL" | sed -E 's#(https?://[^/]+).*#\1#');;
      *) BASE="https://$DOMAIN";; esac
  else BASE="https://$DOMAIN"; fi
}

WP() {
  if [ -n "${MASTER:-}" ] && id "$MASTER" >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    ( cd "$APPDIR" && runuser -u "$MASTER" -- wp "$@" 2>/dev/null )
  else
    ( cd "$APPDIR" && WP_CLI_ALLOW_ROOT=1 wp "$@" 2>/dev/null )
  fi
}

resolve_urls() {
  local path u ans
  if [ -n "${URL:-}" ]; then
    case "$URL" in http://*|https://*) ALLURLS="$URL";; /*) ALLURLS="$BASE$URL";; *) ALLURLS="$BASE/";; esac
  elif [ -n "${PATHS:-}" ]; then
    ALLURLS=""
    for path in $(echo "$PATHS" | tr ',' ' '); do
      case "$path" in http://*|https://*) u="$path";; /*) u="$BASE$path";; *) u="$BASE/$path";; esac
      ALLURLS="$ALLURLS $u"
    done
    ALLURLS=$(echo "$ALLURLS" | sed 's/^ *//')
  else
    ALLURLS="$BASE/"
    ans=$(ask "Paths to check (space/comma). Enter = / only: ")
    if [ -n "$ans" ]; then
      ALLURLS=""
      for path in $(echo "$ans" | tr ',' ' '); do
        case "$path" in http://*|https://*) u="$path";; /*) u="$BASE$path";; *) u="$BASE/$path";; esac
        ALLURLS="$ALLURLS $u"
      done
      ALLURLS=$(echo "$ALLURLS" | sed 's/^ *//')
    fi
  fi
}

# ---------- sections ----------
sec_header() {
  sec "0. HEADER"
  echo "  breeze-check $BC_VERSION  app=$APP domain=$DOMAIN level=$LEVEL"
  echo "  appdir=$APPDIR  logs=$LOGDIR  base=$BASE"
  echo "  urls: $ALLURLS"
  echo "  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -d "$BREEZE" ]; then
    local ver
    ver=$(grep -m1 -E '^[[:space:]]*\*?[[:space:]]*Version:' "$BREEZE/breeze.php" 2>/dev/null | sed -E 's/.*Version:[[:space:]]*//')
    ver=${ver:-$(WP option get breeze_version 2>/dev/null | head -1)}
    good "Breeze plugin present (version ${ver:-unknown})"
    echo "  path=$BREEZE"
  else
    prob "Breeze plugin directory not found at wp-content/plugins/breeze"
  fi
  WP plugin is-active breeze >/dev/null 2>&1 && good "Breeze is active" || warn "Breeze may not be active (wp plugin is-active failed or inactive)"
}

sec_settings() {
  sec "1. BREEZE SETTINGS (file opt / TTL / varnish / preset)"
  local out="$TMP/settings.txt"
  WP eval '
$keys = array("basic_settings","file_settings","advanced_settings","varnish_cache","cdn_integration","preload_settings");
foreach ($keys as $k) {
  $o = function_exists("breeze_get_option") ? breeze_get_option($k) : get_option("breeze_".$k);
  echo "## breeze_$k\n";
  if (!is_array($o)) { echo "  (not array) ".var_export($o,true)."\n"; continue; }
  foreach ($o as $kk=>$vv) {
    if (preg_match("/css|minify|group|purge|ttl|varnish|lazy|cache|emoji|font|cdn|preload|combine/i", (string)$kk)) {
      if (is_array($vv)) $vv = json_encode($vv);
      echo "  $kk = ".$vv."\n";
    }
  }
}
echo "## meta\n";
echo "  breeze_version = ".get_option("breeze_version")."\n";
echo "  breeze_applied_optimization = ".get_option("breeze_applied_optimization")."\n";
echo "  breeze_minify_purged_at = ".get_option("breeze_minify_purged_at")."\n";
echo "  breeze_minify_swept_at = ".get_option("breeze_minify_swept_at")."\n";
' > "$out" 2>/dev/null || true

  if [ ! -s "$out" ]; then
    warn "wp eval could not read Breeze options; trying option get"
    for o in breeze_basic_settings breeze_file_settings breeze_varnish_cache breeze_applied_optimization; do
      echo "  -- $o --"
      WP option get "$o" 2>/dev/null | head -c 1500; echo
    done
  else
    sed 's/^/  /' "$out"
  fi

  # structured flags
  local minify group ttl autopurge applied purged swept
  minify=$(grep -E 'breeze-minify-css' "$out" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | tr -d "\"'")
  group=$(grep -E 'breeze-group-css' "$out" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | tr -d "\"'")
  ttl=$(grep -E 'breeze-b-ttl|breeze-ttl' "$out" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | tr -d "\"'")
  autopurge=$(grep -E 'auto-purge-varnish' "$out" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | tr -d "\"'")
  applied=$(grep -E 'breeze_applied_optimization' "$out" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | tr -d "\"'")
  purged=$(grep -E 'breeze_minify_purged_at' "$out" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | tr -d "\"'")
  swept=$(grep -E 'breeze_minify_swept_at' "$out" 2>/dev/null | head -1 | awk -F'= ' '{print $2}' | tr -d "\"'")

  echo
  echo "  summary: minify-css=${minify:-?} group-css=${group:-?} ttl=${ttl:-?} auto-purge-varnish=${autopurge:-?} applied=${applied:-?}"
  if [ "${minify:-0}" = "1" ] && [ "${group:-0}" = "1" ]; then
    prob "CSS minify + combine (group-css) are ON — exposed to daily combined-CSS / Varnish stale-HTML issue"
  elif [ "${minify:-0}" = "1" ]; then
    warn "CSS minify ON but combine OFF — lower risk than Advanced combine"
  elif [ "${applied:-}" = "advanced" ] || [ "${applied:-}" = "expert" ]; then
    info "Preset was ${applied} but minify/group CSS currently off (workaround state or later change)"
  else
    good "CSS minify/combine not both enabled"
  fi
  if [ -n "${ttl:-}" ] && [ "$ttl" -gt 0 ] 2>/dev/null; then
    info "Purge Cache After (breeze-b-ttl) = ${ttl} minutes (~$((ttl/60))h)"
    [ "$ttl" = "1440" ] && note "Default 1440 min (1 day) daily purge schedule"
  fi
  if [ "${autopurge:-1}" = "0" ]; then
    warn "auto-purge-varnish is OFF — content/minify changes may leave Varnish stale"
  else
    good "auto-purge-varnish is ON"
  fi
  if [ -n "${purged:-}" ] && [ "${purged}" -gt 0 ] 2>/dev/null; then
    echo "  last minify purge mark: $(date -u -d "@$purged" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$purged" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$purged")"
  fi
  if [ -n "${swept:-}" ] && [ "${swept}" -gt 0 ] 2>/dev/null; then
    echo "  last minify orphan sweep: $(date -u -d "@$swept" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$swept" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$swept")"
  fi
}

sec_disk() {
  sec "2. MINIFY / COMBINED CSS ON DISK"
  local cache="$APPDIR/wp-content/cache"
  if [ ! -d "$cache" ]; then
    warn "wp-content/cache missing"
    return
  fi
  echo "  cache dirs:"
  find "$cache" -maxdepth 3 -type d \( -iname '*breeze*' -o -iname '*min*' \) 2>/dev/null | sed 's/^/    /' | head -40
  local css_n js_n
  css_n=$(find "$cache" -type f -name '*.css' 2>/dev/null | wc -l)
  js_n=$(find "$cache" -type f \( -name '*.js' -o -name '*.js.gz' \) 2>/dev/null | wc -l)
  echo "  combined/minified css files: $css_n"
  echo "  combined/minified js files:  $js_n"
  if [ -d "$cache/breeze-minification/css" ]; then
    echo "  recent css under breeze-minification:"
    find "$cache/breeze-minification" -type f \( -name '*.css' -o -name '*.css.gz' \) -printf '    %T+ %s %p\n' 2>/dev/null | sort -r | head -15
    if [ "$css_n" -eq 0 ]; then
      info "breeze-minification/css exists but has no .css files (empty or purged)"
    fi
  else
    info "no breeze-minification/css directory"
  fi
  echo "  breeze page-cache sample:"
  find "$cache/breeze" -type f -name '*.html' -printf '    %T+ %s %p\n' 2>/dev/null | sort -r | head -8
}

sec_cron() {
  sec "3. BREEZE CRON (daily purge + minify sweep)"
  local cron="$TMP/cron.txt"
  WP cron event list --fields=hook,next_run_gmt,recurrence > "$cron" 2>/dev/null || true
  if [ -s "$cron" ]; then
    echo "  breeze-related cron events:"
    grep -iE 'breeze|purge|minify' "$cron" | sed 's/^/    /' || echo "    (none matched)"
  else
    warn "wp cron event list empty/failed"
  fi
  if grep -q 'breeze_purge_cache' "$cron" 2>/dev/null; then
    good "breeze_purge_cache is scheduled (daily TTL purge)"
    grep 'breeze_purge_cache' "$cron" | sed 's/^/    /'
  else
    warn "breeze_purge_cache not scheduled"
  fi
  if grep -q 'breeze_minify_sweep' "$cron" 2>/dev/null; then
    warn "breeze_minify_sweep cron present — can delete combined CSS after purge grace"
    grep 'breeze_minify_sweep' "$cron" | sed 's/^/    /'
  else
    info "no breeze_minify_sweep_* event currently listed"
  fi
}

sec_code_grace() {
  sec "4. CODE: PURGE GRACE vs VARNISH TTL (stale HTML risk)"
  if [ ! -d "$BREEZE" ]; then
    skip "no Breeze plugin tree"
    return
  fi
  local grace_line grace_val
  grace_line=$(grep -n 'breeze_minify_purge_grace\|function purge_grace' "$BREEZE"/inc/minification/breeze-minification-cache.php 2>/dev/null | head -5)
  echo "  purge_grace references:"
  echo "$grace_line" | sed 's/^/    /'
  grace_val=$(grep -A2 'function purge_grace' "$BREEZE"/inc/minification/breeze-minification-cache.php 2>/dev/null | grep -oE '[0-9]+\s*\*\s*MINUTE_IN_SECONDS|[0-9]+\s*\*\s*HOUR_IN_SECONDS|return \(int\).*' | head -1)
  echo "  purge_grace body hint: ${grace_val:-unknown}"
  if grep -q '1 \* MINUTE_IN_SECONDS\|MINUTE_IN_SECONDS' "$BREEZE"/inc/minification/breeze-minification-cache.php 2>/dev/null \
     && grep -q 'function purge_grace' "$BREEZE"/inc/minification/breeze-minification-cache.php 2>/dev/null; then
    if grep -A3 'function purge_grace' "$BREEZE"/inc/minification/breeze-minification-cache.php 2>/dev/null | grep -q '1 \* MINUTE_IN_SECONDS'; then
      prob "Breeze purge_grace is 1 minute — Varnish HTML can live hours/day; orphan CSS sweep can 404 combined CSS"
    else
      warn "purge_grace uses MINUTE_IN_SECONDS — confirm value is >= Varnish HTML TTL"
    fi
  fi

  echo "  daily TTL job (schedule_varnish) excerpt:"
  if [ -f "$BREEZE/inc/cache/purge-per-time.php" ]; then
    sed -n '/function schedule_varnish/,/^        public\|^        }/p' "$BREEZE/inc/cache/purge-per-time.php" 2>/dev/null | head -30 | sed 's/^/    /'
  fi

  echo "  one-click Advanced file defaults:"
  if [ -f "$BREEZE/inc/class-breeze-one-click-optimization.php" ]; then
    grep -n -A20 "'advanced' =>" "$BREEZE/inc/class-breeze-one-click-optimization.php" 2>/dev/null | grep -E "advanced|minify-css|group-css|include-inline-css" | head -20 | sed 's/^/    /'
    if grep -A30 "'advanced' =>" "$BREEZE/inc/class-breeze-one-click-optimization.php" 2>/dev/null | grep -q "breeze-group-css.=>'1'\|'breeze-group-css'[[:space:]]*=>[[:space:]]*'1'"; then
      note "One-click Advanced enables breeze-group-css=1 (combine CSS)"
    fi
  fi

  # Varnish beresp.ttl hints
  echo "  Cloudways Varnish HTML TTL hints:"
  if [ -f /etc/varnish/backend_response/phpstack.vcl ]; then
    grep -nE 'beresp.ttl|cache-control|max-age' /etc/varnish/backend_response/phpstack.vcl 2>/dev/null | head -10 | sed 's/^/    /'
    if grep -q 'beresp.ttl = 1d\|beresp.ttl=1d' /etc/varnish/backend_response/phpstack.vcl 2>/dev/null; then
      warn "Varnish phpstack beresp.ttl is 1 day — far longer than Breeze 1-minute minify grace"
    fi
  else
    info "no /etc/varnish/backend_response/phpstack.vcl"
  fi
}

sec_edge_css() {
  sec "5. EDGE HTML vs COMBINED CSS (live)"
  local u edge bust hdr_e hdr_b html_e html_b
  for u in $ALLURLS; do
    echo "  -- $u --"
    hdr_e="$TMP/edge.hdr"; html_e="$TMP/edge.html"
    hdr_b="$TMP/bust.hdr"; html_b="$TMP/bust.html"
    curl -sS -D "$hdr_e" -o "$html_e" -A "$UA" "$u" 2>/dev/null || true
    local bust_url
    case "$u" in
      *\?*) bust_url="${u}&nocache=$(date +%s)";;
      *) bust_url="${u}?nocache=$(date +%s)";;
    esac
    curl -sS -D "$hdr_b" -o "$html_b" -A "$UA" "$bust_url" 2>/dev/null || true

    echo "  edge headers:"
    grep -iE 'HTTP/|x-cache|age:|cache-control|via:|x-varnish' "$hdr_e" 2>/dev/null | sed 's/^/    /' || true
    echo "  bust headers:"
    grep -iE 'HTTP/|x-cache|age:|cache-control|via:|x-varnish' "$hdr_b" 2>/dev/null | sed 's/^/    /' || true

    if grep -qiE 'x-cache:[[:space:]]*HIT' "$hdr_e" 2>/dev/null; then
      good "edge is caching HTML (x-cache HIT)"
    elif grep -qiE 'x-cache:[[:space:]]*MISS' "$hdr_e" 2>/dev/null; then
      info "edge MISS on this probe"
    else
      info "no x-cache header on edge response"
    fi

    echo "  combined/minified CSS refs in EDGE html:"
    local refs
    refs=$(grep -oiE '/wp-content/cache/breeze-minification/[^"'\'' ]+\.css' "$html_e" 2>/dev/null | sort -u)
    if [ -z "$refs" ]; then
      info "no breeze-minification CSS linked in edge HTML (combine likely off or not yet built)"
    else
      echo "$refs" | sed 's/^/    /'
      local rel st code size disk
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        code=$(curl -sS -o /dev/null -w '%{http_code} %{size_download}' -A "$UA" "$BASE$rel" 2>/dev/null || echo "000 0")
        st=$(echo "$code" | awk '{print $1}'); size=$(echo "$code" | awk '{print $2}')
        disk="$APPDIR$rel"
        disk=${disk%%\?*}
        if [ "$st" = "404" ] || [ "$st" = "403" ]; then
          prob "CSS $st for $rel (size=$size) — stale HTML pointing at missing combined CSS"
        elif [ ! -f "$disk" ] && [ "$st" != "200" ]; then
          warn "CSS HTTP $st and disk missing: $rel"
        elif [ ! -f "$disk" ]; then
          warn "CSS HTTP $st but disk file missing: $rel"
        else
          good "CSS HTTP $st ($size bytes) and on disk: $rel"
        fi
      done << EOF
$refs
EOF
    fi

    echo "  all stylesheet hrefs (first 25):"
    grep -oE 'href=["'\''][^"'\'']+\.css[^"'\'']*' "$html_e" 2>/dev/null \
      | sed 's/^href=//;s/["'\'']//g' | head -25 | sed 's/^/    /' || true
  done
}

sec_logs_404() {
  sec "6. HISTORICAL COMBINED CSS 404s (access logs)"
  if [ ! -d "$LOGDIR" ]; then
    skip "no log dir"
    return
  fi
  local agg="$TMP/css_hits.txt"
  : > "$agg"
  # static logs are where CSS usually appears on Cloudways
  zgrep -hE 'breeze-minification/.*\.css|/cache/breeze[^ ]*\.css' \
    "$LOGDIR"/static_*.log* "$LOGDIR"/backend_*.log* 2>/dev/null \
    | awk -F'"' '
        NF>=3 {
          split($2, r, " ");
          split($3, a, " ");
          path=r[2]; st=a[1];
          if (path ~ /\.css/ && st ~ /^[0-9]+$/) {
            sub(/\?.*/, "", path);
            print st, path;
          }
        }' >> "$agg" 2>/dev/null || true

  if [ ! -s "$agg" ]; then
    info "no breeze-minification CSS hits in retained logs"
    return
  fi

  echo "  top combined CSS status/path:"
  awk '{print $1,$2}' "$agg" | sort | uniq -c | sort -rn | head -25 | sed 's/^/    /'

  local n404
  n404=$(awk '$1==404{c++} END{print c+0}' "$agg")
  echo "  combined CSS 404 count in retained logs: $n404"
  if [ "$n404" -gt 0 ]; then
    prob "Found $n404 historical 404s for breeze-minification CSS — matches stale HTML / deleted combine files"
    echo "  sample 404 lines:"
    zgrep -hE 'breeze-minification/.*\.css' "$LOGDIR"/static_*.log* 2>/dev/null | grep ' 404 ' | tail -15 | sed 's/^/    /'
  else
    good "no combined CSS 404s in retained logs"
  fi

  echo "  timeline (first/last combined CSS hit):"
  zgrep -hE 'breeze-minification/.*\.css' "$LOGDIR"/static_*.log* 2>/dev/null \
    | awk -F'[][]' 'NF>1{print $2}' | sed 's/ +0000//' | sort | sed -n '1p;$p' | sed 's/^/    /'
}

sec_varnish() {
  sec "7. VARNISH PRESENCE"
  if pgrep -x varnishd >/dev/null 2>&1 || pgrep -f cache-main >/dev/null 2>&1; then
    good "Varnish/cache-main process is running"
    ps auxww | grep -iE 'varnishd|cache-main' | grep -v grep | head -5 | sed 's/^/    /'
  else
    warn "no varnishd/cache-main process seen"
  fi
  ss -lntp 2>/dev/null | grep -E ':8080|:6082' | sed 's/^/    /' | head -10 || true
  if command -v varnishstat >/dev/null 2>&1; then
    varnishstat -1 2>/dev/null | grep -iE 'MAIN.cache_hit |MAIN.cache_miss |MAIN.n_object |MAIN.client_req ' | sed 's/^/    /' | head -10
  fi
}

sec_code_full() {
  sec "8. KEY CODE PATHS (full level)"
  [ -d "$BREEZE" ] || { skip "no plugin"; return; }
  echo "  -- clear_minification / mark_purge / maybe_sweep_orphans --"
  if [ -f "$BREEZE/inc/minification/breeze-minification-cache.php" ]; then
    grep -n 'function clear_minification\|function mark_purge\|function purge_grace\|function maybe_sweep_orphans\|breeze_minify_sweep' \
      "$BREEZE/inc/minification/breeze-minification-cache.php" | head -30 | sed 's/^/    /'
    echo "  purge_grace():"
    sed -n '/function purge_grace/,/^        public\|^        }/p' \
      "$BREEZE/inc/minification/breeze-minification-cache.php" 2>/dev/null | head -20 | sed 's/^/    /'
    echo "  maybe_sweep_orphans() head:"
    sed -n '/function maybe_sweep_orphans/,/^        public\|^        }/p' \
      "$BREEZE/inc/minification/breeze-minification-cache.php" 2>/dev/null | head -50 | sed 's/^/    /'
  fi
  echo "  -- breeze_clear_varnish listeners --"
  grep -Rn "breeze_clear_varnish" "$BREEZE" --include='*.php' 2>/dev/null | head -20 | sed 's/^/    /'
  echo "  -- content_hash comment (documents Varnish stale HTML) --"
  grep -n -A8 'content_hash' "$BREEZE/inc/minification/breeze-minification-cache.php" 2>/dev/null | head -20 | sed 's/^/    /'
}

sec_summary() {
  sec "FINDINGS SUMMARY  app=$APP domain=$DOMAIN level=$LEVEL  ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo
  echo "  This check looks for: Advanced/combine CSS + daily minify purge/sweep"
  echo "  deleting combined CSS while Varnish still serves HTML that links to them."
  echo
  echo " PROBLEMS (${#PROB[@]})"
  if [ "${#PROB[@]}" -eq 0 ]; then echo "   (none)"; else printf '   - %s\n' "${PROB[@]}"; fi
  echo " WARNINGS (${#WARNS[@]})"
  if [ "${#WARNS[@]}" -eq 0 ]; then echo "   (none)"; else printf '   - %s\n' "${WARNS[@]}"; fi
  echo " NOTES (${#NOTES[@]})"
  if [ "${#NOTES[@]}" -eq 0 ]; then echo "   (none)"; else printf '   - %s\n' "${NOTES[@]}"; fi
  echo " INFO (${#INFOS[@]})"
  if [ "${#INFOS[@]}" -eq 0 ]; then echo "   (none)"; else printf '   - %s\n' "${INFOS[@]}"; fi
  echo
  echo " Suggested customer workaround if PROBLEM on combine CSS:"
  echo "   - Turn off CSS Minify / Combine CSS, or use One-click Basic (not Advanced)"
  echo "   - Temporary: Breeze → Purge Varnish after unstyled pages appear"
  echo " Product fix: raise breeze_minify_purge_grace to >= Varnish HTML TTL,"
  echo "   and/or always purge Varnish when deleting minify assets."
  echo
  echo " Full report: $REPORT"
  echo " Indicators are not proof — confirm against sections above before telling the customer."
}

# ---------- main ----------
main() {
  get_inputs "$@"
  STARTED=$(date -u +%Y%m%dT%H%M%SZ)
  TMP=$(mktemp -d /tmp/breeze-check.XXXXXX)
  trap 'rm -rf "$TMP"' EXIT
  discover
  resolve_urls
  REPORT=/tmp/breeze-check-${APP}-${STARTED}.txt

  {
    sec_header
    sec_settings
    sec_disk
    sec_cron
    case "$LEVEL" in
      quick)
        sec_edge_css
        sec_varnish
        ;;
      standard)
        sec_code_grace
        sec_edge_css
        sec_logs_404
        sec_varnish
        ;;
      full)
        sec_code_grace
        sec_edge_css
        sec_logs_404
        sec_varnish
        sec_code_full
        ;;
    esac
    sec_summary
  } | tee "$REPORT"
}

main "$@"
