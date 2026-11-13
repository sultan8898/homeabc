#!/bin/bash
# Run checks.py for every WordPress app on the server.
#
# Usage: ./run_checks_all.sh [--skip-plugins] [--output-dir DIR]
#
# Requires: python3, checks.py dependencies (see requirements.txt)

if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    echo "Do not pipe this script to bash. Run install_case_tools.sh first." >&2
    exit 1
fi
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/case_tools_load.sh"
set -euo pipefail

SKIP_PLUGINS=0
OUTPUT_DIR="${CASE_CHECKS_OUTPUT:-/home/master/case_reports}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-plugins) SKIP_PLUGINS=1; shift ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

CHECKS_PY="$CASE_TOOLS_DIR/checks.py"
[[ -f "$CHECKS_PY" ]] || { echo "checks.py not found beside this script." >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
STAMP=$(date +%Y%m%d_%H%M%S)

echo "Writing reports under $OUTPUT_DIR (stamp $STAMP)"

for app in $(case_list_apps); do
    wp_root=$(case_find_wp_root "$app") || continue
    site_url=$(case_primary_site_url "$app" 2>/dev/null) || continue
    log_path="$APPS_BASE/$app/logs"
    out_sub="$OUTPUT_DIR/${app}_${STAMP}"
    mkdir -p "$out_sub"

    echo ""
    echo "=========================================================="
    echo " checks.py: $app -> $site_url"
    echo " logs: $log_path"
    echo "=========================================================="

    extra=()
    [[ "$SKIP_PLUGINS" -eq 1 ]] && extra+=(--skip-plugins)

    if python3 "$CHECKS_PY" "$site_url" --log-path "$log_path" --output-path "$out_sub/" "${extra[@]}"; then
        echo "OK: $app"
    else
        echo "FAILED: $app (see above)" >&2
    fi
done

echo ""
echo "Done. Reports in $OUTPUT_DIR"
