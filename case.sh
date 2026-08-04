#!/bin/bash
# Run homeabc case tools with NO permanent install (uses /tmp, removed on exit).
#
#   curl -fsSL https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/cursor/case-investigation-scripts-c2b2/case.sh | bash -s -- help
#
# Examples:
#   curl -fsSL .../case.sh | bash -s -- triage 2000 afurtxebjn
#   curl -fsSL .../case.sh | bash -s -- slice -a afurtxebjn -d 04/08/2026 -f 14:00 -u 14:45 --status 499
#   curl -fsSL .../case.sh | bash -s -- ip afurtxebjn 203.0.113.1 3000
#
# Keep temp files for debugging: CASE_KEEP_TMP=1 curl ... | bash -s -- triage 2000 afurtxebjn

CASE_RAW_BASE="${CASE_RAW_BASE:-https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/cursor/case-investigation-scripts-c2b2}"

case__fetch_toolkit() {
    local dest="$1"
    local files=(
        case_lib.sh
        case_tools_load.sh
        case_triage.sh
        case_slice.sh
        case_ip.sh
        cache_ratio.sh
        fpm_status.sh
        redis_diag.sh
        cron_audit.sh
        mysql_case.sh
        disk_check.sh
        run_checks_all.sh
        location.sh
        all_check.sh
    )
    local f
    for f in "${files[@]}"; do
        if [[ ! -f "$dest/$f" ]]; then
            curl -fsSL "${CASE_RAW_BASE}/${f}" -o "$dest/$f" || {
                echo "case.sh: failed to download ${f} from ${CASE_RAW_BASE}" >&2
                return 1
            }
        fi
    done
    chmod +x "$dest"/*.sh 2>/dev/null || true
    return 0
}

case__usage() {
    cat <<EOF
Usage: curl -fsSL ${CASE_RAW_BASE}/case.sh | bash -s -- <command> [args...]

No permanent install — scripts are cached under /tmp for this run only.

Commands:
  triage [N] [app|all]          Quick hypothesis (start here)
  slice [case_slice.sh args]    Log time window ( -a APP -d DD/MM/YYYY -f HH:MM -u HH:MM ... )
  ip APP IP [N] [--include-gz]  Drill-down one IP
  cache APP [N] [--include-gz]  Cache / backend hit ratio
  fpm [app|all]                 PHP-FPM pressure
  redis [app]                   Redis + optional wp redis status
  cron [app|all]                wp-cron / Action Scheduler
  mysql [--running-seconds N]   MySQL processlist + slow log
  disk                          Disk / inode / log sizes
  audit [N]                     Full all_check.sh server audit
  location LOGFILE              Geo hits from one nginx status log
  help                          This message

Examples (app slug afurtxebjn):
  curl -fsSL ${CASE_RAW_BASE}/case.sh | bash -s -- triage 2000 afurtxebjn
  curl -fsSL ${CASE_RAW_BASE}/case.sh | bash -s -- slice -a afurtxebjn -d 04/08/2026 -f 14:00 -u 14:45 --status 499
  curl -fsSL ${CASE_RAW_BASE}/case.sh | bash -s -- ip afurtxebjn 1.2.3.4 3000
  curl -fsSL ${CASE_RAW_BASE}/case.sh | bash -s -- cache afurtxebjn 3000
  curl -fsSL ${CASE_RAW_BASE}/case.sh | bash -s -- audit 3000

Env:
  CASE_KEEP_TMP=1    Do not delete /tmp cache after run
  CASE_RAW_BASE=...  Alternate git raw URL (branch/path)
EOF
}

case__main() {
    local cmd="${1:-help}"
    if [[ "$cmd" == "help" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
        case__usage
        return 0
    fi

    local tmp="${CASE_TMPDIR:-}"
    if [[ -z "$tmp" ]]; then
        tmp=$(mktemp -d /tmp/case-tools.XXXXXX) || exit 1
        export CASE_TMPDIR="$tmp"
        if [[ "${CASE_KEEP_TMP:-0}" != "1" ]]; then
            trap 'rm -rf "$CASE_TMPDIR"' EXIT
        else
            echo "case.sh: keeping tools in $CASE_TMPDIR" >&2
        fi
    fi

    export CASE_TOOLS_DIR="$tmp"
    case__fetch_toolkit "$tmp" || exit 1

    shift
    case "$cmd" in
        triage)
            exec bash "$tmp/case_triage.sh" "$@"
            ;;
        slice)
            exec bash "$tmp/case_slice.sh" "$@"
            ;;
        ip)
            exec bash "$tmp/case_ip.sh" "$@"
            ;;
        cache)
            exec bash "$tmp/cache_ratio.sh" "$@"
            ;;
        fpm)
            exec bash "$tmp/fpm_status.sh" "$@"
            ;;
        redis)
            exec bash "$tmp/redis_diag.sh" "$@"
            ;;
        cron)
            exec bash "$tmp/cron_audit.sh" "$@"
            ;;
        mysql)
            exec bash "$tmp/mysql_case.sh" "$@"
            ;;
        disk)
            exec bash "$tmp/disk_check.sh" "$@"
            ;;
        audit|allcheck|all_check|all-check)
            exec bash "$tmp/all_check.sh" "$@"
            ;;
        location)
            exec bash "$tmp/location.sh" "$@"
            ;;
        checks)
            if [[ ! -f "$tmp/checks.py" ]]; then
                curl -fsSL "${CASE_RAW_BASE}/checks.py" -o "$tmp/checks.py" || exit 1
            fi
            exec bash "$tmp/run_checks_all.sh" "$@"
            ;;
        *)
            echo "Unknown command: $cmd" >&2
            case__usage >&2
            exit 1
            ;;
    esac
}

case__main "$@"
