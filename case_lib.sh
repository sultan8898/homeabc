#!/bin/bash
# Shared helpers for case_* investigation scripts (Cloudways app log layout).
# Source from other scripts:  source "$(dirname "$0")/case_lib.sh"

if [[ -z "${APPS_BASE:-}" ]]; then
    if [[ -d /home/master/applications ]]; then
        APPS_BASE="/home/master/applications"
    else
        _hid=$(hostname 2>/dev/null | grep -oE '^[0-9]+' || true)
        if [[ -n "$_hid" && -d "/home/${_hid}.cloudwaysapps.com" ]]; then
            APPS_BASE="/home/${_hid}.cloudwaysapps.com"
        else
            APPS_BASE="/home/master/applications"
        fi
    fi
fi
export APPS_BASE

case_list_apps() {
    ls -l "$APPS_BASE" 2>/dev/null | awk '/^d/ {print $NF}' | grep -v '^\.$'
}

case_resolve_app() {
    local app="$1"
    APP_NAME="$app"
    APP_DIR="$APPS_BASE/$app"
    LOG_DIR="$APP_DIR/logs"
    DOMAIN=""
    APP_PREFIX=""
    NGINX_STATUS_LOG=""
    ACCESS_LOG=""
    PHP_ACCESS_LOG=""
    SLOW_LOG=""
    PUBLIC_HTML="$APP_DIR/public_html"

    if [[ ! -d "$APP_DIR" ]]; then
        echo "case_resolve_app: unknown app '$app' (no $APP_DIR)" >&2
        return 1
    fi

    local nginxconf="$APP_DIR/conf/server.nginx"
    if [[ -f "$nginxconf" ]]; then
        DOMAIN=$(awk 'NR==1 {print substr($NF, 1, length($NF)-1)}' "$nginxconf" 2>/dev/null)
        APP_PREFIX=$(grep -oP '[a-zA-Z0-9_]+-[0-9]+-[0-9]+(?=\.cloudwaysapps\.com)' "$nginxconf" 2>/dev/null | head -n 1)
    fi

    if [[ -n "$APP_PREFIX" ]]; then
        NGINX_STATUS_LOG="$LOG_DIR/nginx-app.status.log"
        ACCESS_LOG="$LOG_DIR/backend_${APP_PREFIX}.cloudwaysapps.com.access.log"
        PHP_ACCESS_LOG="$LOG_DIR/php-app.access.log"
        SLOW_LOG="$LOG_DIR/php-app.slow.log"
    fi
    return 0
}

# Convert DD/MM/YYYY HH:MM to nginx log prefix DD/Mon/YYYY:HH:MM (17 chars for minute granularity)
case_nginx_time_key() {
    local d="$1" t="$2"
    date -d "${d//\//-} ${t}" +"%d/%b/%Y:%H:%M" 2>/dev/null
}

case_nginx_time_key_sec() {
    local d="$1" t="$2"
    date -d "${d//\//-} ${t}" +"%d/%b/%Y:%H:%M:%S" 2>/dev/null
}

# Stream log lines: current file plus optional rotated/gzip siblings.
# Usage: case_log_stream "/path/to/nginx-app.status.log" [include_gz]
case_log_stream() {
    local base="$1"
    local include_gz="${2:-0}"
    [[ -f "$base" ]] && cat "$base" 2>/dev/null
    if [[ "$include_gz" == "1" ]]; then
        local dir basefile
        dir=$(dirname "$base")
        basefile=$(basename "$base")
        shopt -s nullglob
        for f in "$dir"/"${basefile}".* "$dir"/"${basefile}"-*.gz "$dir"/"${basefile}".gz; do
            [[ -f "$f" ]] || continue
            [[ "$f" == "$base" ]] && continue
            case "$f" in
                *.gz) zcat -f "$f" 2>/dev/null ;;
                *)    cat "$f" 2>/dev/null ;;
            esac
        done
        shopt -u nullglob
    fi
}

# Last N lines from current log, optionally with gz tail (expensive: merges then tail).
case_log_tail() {
    local base="$1"
    local n="$2"
    local include_gz="${3:-0}"
    if [[ "$include_gz" == "1" ]]; then
        case_log_stream "$base" 1 | tail -n "$n"
    else
        tail -n "$n" "$base" 2>/dev/null
    fi
}

case_primary_site_url() {
    local app="$1"
    case_resolve_app "$app" || return 1
    local nginxconf="$APP_DIR/conf/server.nginx"
    local primary="" default=""
    if [[ -f "$nginxconf" ]]; then
        while read -r n; do
            [[ -z "$n" || "$n" == "_" || "$n" == "localhost" ]] && continue
            if [[ "$n" == *.cloudwaysapps.com ]]; then
                default="$n"
            else
                primary="$n"
            fi
        done < <(grep -hoP 'server_name\s+\K[^;]+' "$nginxconf" 2>/dev/null | tr ' ' '\n' | sort -u)
    fi
    local host="${primary:-$default}"
    [[ -z "$host" ]] && return 1
    echo "https://${host}"
}

case_find_wp_root() {
    local app="$1"
    case_resolve_app "$app" || return 1
    find "$PUBLIC_HTML" -maxdepth 4 -name wp-config.php 2>/dev/null \
        | awk '{print gsub(/\//,"/"), $0}' | sort -n | head -1 | cut -d' ' -f2- | xargs dirname 2>/dev/null
}
