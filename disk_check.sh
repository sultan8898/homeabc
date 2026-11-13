#!/bin/bash
# Disk, inode, and application log directory size check.
#
# Usage: ./disk_check.sh

set -euo pipefail

APPS_BASE="${APPS_BASE:-/home/master/applications}"

echo "=========================================================="
echo " DISK CHECK  $(date)"
echo "=========================================================="

echo ""
echo "--- Filesystem usage ---"
df -hT 2>/dev/null | grep -E '^Filesystem|/dev/|/home' || df -h

echo ""
echo "--- Inode usage ---"
df -hi 2>/dev/null | grep -E '^Filesystem|/dev/|/home' || df -i

echo ""
echo "--- Largest paths under /home/master (depth 2) ---"
du -xh --max-depth=2 /home/master 2>/dev/null | sort -hr | head -n 20 || true

echo ""
echo "--- Per-app log directory sizes ---"
for app in $(ls -l "$APPS_BASE" 2>/dev/null | awk '/^d/ {print $NF}'); do
    logdir="$APPS_BASE/$app/logs"
    [[ -d "$logdir" ]] || continue
  du -sh "$logdir" 2>/dev/null | awk -v a="$app" '{print $1 "\t" a "\tlogs"}'
done | sort -hr | head -n 15

echo ""
echo "--- Largest single log files (top 15) ---"
find "$APPS_BASE" -path '*/logs/*' -type f \( -name '*.log' -o -name '*.gz' \) -printf '%s %p\n' 2>/dev/null \
    | sort -nr | head -n 15 | awk '{printf "%.1f MB\t%s\n", $1/1024/1024, $2}'

echo ""
echo "--- MySQL / var log dirs ---"
for d in /var/log/mysql /var/log/nginx /var/log; do
    [[ -d "$d" ]] && du -sh "$d" 2>/dev/null
done
