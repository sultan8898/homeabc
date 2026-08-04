#!/bin/bash
# Download homeabc case investigation scripts to this server.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/cursor/case-investigation-scripts-c2b2/install_case_tools.sh | bash
#
# Optional:
#   CASE_TOOLS_DIR=/path/to/dir curl -fsSL ... | bash

set -euo pipefail

BRANCH_PATH="cursor/case-investigation-scripts-c2b2"
RAW="https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/${BRANCH_PATH}"

hid=$(hostname 2>/dev/null | grep -oE '^[0-9]+' || true)
if [[ -n "${CASE_TOOLS_DIR:-}" ]]; then
    INSTALL_DIR="$CASE_TOOLS_DIR"
elif [[ -d /home/master/applications ]]; then
    INSTALL_DIR="/home/master/case-tools"
elif [[ -n "$hid" ]]; then
    INSTALL_DIR="/home/${hid}.cloudwaysapps.com/case-tools"
else
    INSTALL_DIR="${HOME}/case-tools"
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

FILES=(
    case_lib.sh
    case_tools_load.sh
    case_slice.sh
    case_ip.sh
    case_triage.sh
    cache_ratio.sh
    fpm_status.sh
    redis_diag.sh
    cron_audit.sh
    mysql_case.sh
    disk_check.sh
    run_checks_all.sh
    location.sh
    all_check.sh
    checks.py
    requirements.txt
)

echo "Installing to: $INSTALL_DIR"
for f in "${FILES[@]}"; do
    echo "  -> $f"
    curl -fsSL "${RAW}/${f}" -o "$f"
    chmod +x "$f" 2>/dev/null || true
done

chmod +x *.sh 2>/dev/null || true

cat <<EOF

Done. Add to your shell (optional):

  export CASE_TOOLS_DIR="$INSTALL_DIR"
  export PATH="\$CASE_TOOLS_DIR:\$PATH"

Run examples (app slug = folder under applications/, e.g. afurtxebjn):

  cd "$INSTALL_DIR"
  ./case_triage.sh 2000 afurtxebjn
  ./case_slice.sh -a afurtxebjn -d 04/08/2026 -f 14:00 -u 14:45 --status 499
  ./case_ip.sh afurtxebjn 203.0.113.1 3000
  ./cache_ratio.sh afurtxebjn 3000
  ./fpm_status.sh afurtxebjn
  ./redis_diag.sh afurtxebjn
  ./cron_audit.sh afurtxebjn
  ./mysql_case.sh
  ./disk_check.sh
  ./all_check.sh 3000

From an app logs directory (location.sh only):

  cd /home/${hid:-MASTER}.cloudwaysapps.com/afurtxebjn/logs
  "$INSTALL_DIR/location.sh" nginx-app.status.log

EOF
