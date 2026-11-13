#!/bin/bash
# quick_stall_check.sh — find what PHP workers are stuck on, then run server audit
#
# Usage:
#   quick_stall_check.sh [options] [pool] [audit_lines]
#
# Options:
#   --stall-only    Kernel/FPM stall diagnostics only (skip all_check audit)
#   --audit-only    Run all_check traffic/CPU audit only (skip stall section)
#   --remote-audit  Force curl of all_check.sh (ignore local copy)
#
# Args:
#   pool          Optional Cloudways app folder name (limits slow-log section)
#   audit_lines   Lines per log for all_check (default 1000; use 5000+ during incidents)
#
# One-liner (remote audit):
#   curl -fsSL https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/cursor/quick-stall-check-a7b8/quick_stall_check.sh | bash
#
set -euo pipefail

POOL=""
AUDIT_LINES=1000
RUN_STALL=1
RUN_AUDIT=1
FORCE_REMOTE_AUDIT=0
ALL_CHECK_URL="https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/cursor/daily-top-ips-37cd/all_check.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --stall-only)
            RUN_AUDIT=0
            shift
            ;;
        --audit-only)
            RUN_STALL=0
            shift
            ;;
        --remote-audit)
            FORCE_REMOTE_AUDIT=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [ -z "$POOL" ]; then
                POOL="$1"
            elif [[ "$1" =~ ^[0-9]+$ ]]; then
                AUDIT_LINES="$1"
            else
                echo "Unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

while [ $# -gt 0 ]; do
    if [ -z "$POOL" ]; then
        POOL="$1"
    elif [[ "$1" =~ ^[0-9]+$ ]]; then
        AUDIT_LINES="$1"
    else
        echo "Unexpected argument: $1" >&2
        exit 1
    fi
    shift
done

section() {
    echo
    echo "=================================================================="
    echo " $1"
    echo "=================================================================="
}

wchan_hint() {
  case "$1" in
    do_rmdir|vfs_unlink|security_inode_remove) echo "file deletion (rmdir/unlink)" ;;
    iterate_dir|lookup_slow|walk_component)    echo "directory walk / path lookup" ;;
    io_schedule|folio_wait|request_wait_answer) echo "disk IO wait" ;;
    jbd2_journal_commit|jbd2_log_wait_commit)  echo "ext4 journal commit (disk saturated)" ;;
    rpc_wait_bit_killable|rpc_wait)            echo "NFS / network FS" ;;
    futex_wait_queue|pipe_wait)                echo "lock/pipe wait (may be normal)" ;;
    *)                                         echo "see /proc/PID/wchan + stack" ;;
  esac
}

slow_log_paths() {
    local app log
    for log in /home/master/applications/*/logs/php-app.slow.log; do
        [ -f "$log" ] || continue
        app=$(echo "$log" | awk -F/ '{print $(NF-2)}')
        if [ -n "$POOL" ] && [ "$app" != "$POOL" ]; then
            continue
        fi
        printf '%s\n' "$log"
    done
}

run_server_audit() {
    section "SERVER AUDIT (all_check.sh — traffic, IPs, cache bypass, saturation)"
    if [ "$FORCE_REMOTE_AUDIT" -eq 0 ] && [ -f "$SCRIPT_DIR/all_check.sh" ]; then
        echo "(using local $SCRIPT_DIR/all_check.sh, lines=$AUDIT_LINES)"
        bash "$SCRIPT_DIR/all_check.sh" "$AUDIT_LINES"
        return
    fi
    echo "(fetching $ALL_CHECK_URL, lines=$AUDIT_LINES)"
    curl -fsSL "$ALL_CHECK_URL" | bash -s -- "$AUDIT_LINES"
}

if [ "$RUN_STALL" -eq 1 ]; then
    section "1. D-state processes and kernel wait channel"
    echo "Legend: D = uninterruptible sleep (usually disk/NFS/filesystem)"
    D_COUNT=$(ps -eo stat 2>/dev/null | awk '$1 ~ /^D/ {c++} END {print c+0}')
    echo "Total D-state processes: $D_COUNT"
  if [ "$D_COUNT" -gt 0 ]; then
    printf '%-8s %-10s %-8s %-26s %5s %10s %s\n' PID USER STAT WCHAN CPU ELAPSED CMD
    while read -r pid user stat wchan cpu etime cmd; do
        hint=$(wchan_hint "$wchan")
        printf '%-8s %-10s %-8s %-26s %5s %10s %s\n' "$pid" "$user" "$stat" "$wchan" "$cpu" "$etime" "$cmd"
        printf '         => %s\n' "$hint"
    done < <(ps -eo pid=,user=,stat=,wchan:25=,%cpu=,etime=,cmd= --sort=stat 2>/dev/null | awk '$3 ~ /^D/')
  else
    echo "(none right now — good sign)"
  fi

    section "2. Stuck php-fpm workers: open files + pool"
    FPM_D=0
    while read -r pid stat cmd; do
        FPM_D=$((FPM_D + 1))
        pool=$(echo "$cmd" | sed -n 's/.*pool \([^ ]*\).*/\1/p')
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo '?')
        echo "--- PID $pid pool=${pool:-?} (cwd: $cwd) ---"
        if [ -r "/proc/$pid/stack" ]; then
            echo "kernel stack (top):"
            sed -n '1,6p' "/proc/$pid/stack" 2>/dev/null | sed 's/^/  /'
        fi
        ls -l "/proc/$pid/fd" 2>/dev/null \
            | awk '{print $NF}' \
            | grep -vE '^(socket|pipe|/dev|anon_inode)' \
            | tail -8 \
            | sed 's/^/  /' || echo "  (no regular files open)"
    done < <(ps -eo pid=,stat=,cmd= 2>/dev/null | awk '$2 ~ /^D/ && /php-fpm/ {print}')
    [ "$FPM_D" -eq 0 ] && echo "(no php-fpm processes in D-state)"

    section "3. PHP slow-log: last hour + top stuck frames"
    HOUR_TAG=$(date -u '+%d-%b-%Y %H:')
    HOUR_LOCAL=$(date '+%d-%b-%Y %H:')
    FOUND_SLOW=0
    while IFS= read -r sl; do
        app=$(echo "$sl" | awk -F/ '{print $(NF-2)}')
        FOUND_SLOW=1
        echo "--- $app ---"
        events=$(grep -cE "($HOUR_TAG|$HOUR_LOCAL)" "$sl" 2>/dev/null || true)
        echo "slow-log events this hour (UTC/local): $events"
        grep -E "($HOUR_TAG|$HOUR_LOCAL)" "$sl" 2>/dev/null \
            | grep -oE '\] [a-zA-Z_0-9:>-]+\(\) [^ ]+:[0-9]+' \
            | sed 's/^\] //' \
            | sort | uniq -c | sort -rn | head -5 \
            | sed 's/^/  /' || echo "  (no frames this hour)"
        echo "top entry scripts (all time, tail 5000):"
        tail -n 5000 "$sl" 2>/dev/null \
            | grep -oP 'script_filename = \K.*' \
            | sort | uniq -c | sort -rn | head -3 \
            | sed 's/^/  /' || true
    done < <(slow_log_paths)
    [ "$FOUND_SLOW" -eq 0 ] && echo "(no slow logs matched${POOL:+ for pool $POOL})"

    section "4. MySQL threads blocking FPM (live processlist)"
    if command -v mysql >/dev/null 2>&1; then
        mysql -N -e "
            SELECT CONCAT(ID,' ',USER,' ',TIME,'s ',STATE,' | ',LEFT(IFNULL(INFO,''),80))
            FROM information_schema.PROCESSLIST
            WHERE COMMAND != 'Sleep'
            ORDER BY TIME DESC
            LIMIT 12;" 2>/dev/null | sed 's/^/  /' \
            || echo "  (mysql query failed — credentials/socket?)"
    else
        echo "  (mysql client not installed)"
    fi

    section "5. Live CPU split (who is burning cycles now)"
    ps -eo user,%cpu,%mem,etime,cmd --sort=-%cpu 2>/dev/null | head -12

    section "6. Disk/memory pressure (why D-states hang)"
    uptime
    echo
    echo "vmstat (1s x3 — high wa=IO bound, high si/so=swap thrash):"
    vmstat 1 3 2>/dev/null | tail -2
    echo
    df -h /home 2>/dev/null | tail -1
    df -i /home 2>/dev/null | tail -1
    echo
    echo "iostat snapshot (if available):"
    if command -v iostat >/dev/null 2>&1; then
        iostat -xz 1 2 2>/dev/null | tail -n +4 | tail -8
    else
        echo "  (iostat not installed)"
    fi

    section "7. FPM pool saturation + listen backlog"
    for conf in /etc/php/*/fpm/pool.d/*.conf /etc/phppool.d/*.conf; do
        [ -f "$conf" ] || continue
        pn=$(awk -F'[][]' '/^\[/{print $2; exit}' "$conf")
        [ -n "$POOL" ] && [ "$pn" != "$POOL" ] && continue
        max=$(awk -F= '/^pm.max_children/{gsub(/ /,"");print $2}' "$conf")
        cur=$(pgrep -cf "php-fpm: pool $pn" 2>/dev/null || echo 0)
        [ -n "$max" ] && echo "$pn: $cur / $max workers"
    done
    echo
    echo "php-fpm sockets (Recv-Q = queued connections waiting for a worker):"
    ss -lntp 2>/dev/null | grep -E 'php-fpm|php[0-9.]*-fpm' | awk '{printf "  %s Recv-Q=%s\n", $0, $2}' || true

    section "8. Recent upstream/FPM errors (nginx error logs, last 30m window)"
    err_found=0
    for elog in /home/master/applications/*/logs/*error.log; do
        [ -f "$elog" ] || continue
        app=$(echo "$elog" | awk -F/ '{print $(NF-3)}')
        [ -n "$POOL" ] && [ "$app" != "$POOL" ] && continue
        hits=$(tail -n 2000 "$elog" 2>/dev/null \
            | grep -ciE 'upstream timed out|connect\(\) failed|no live upstreams|recv\(\) failed|worker_connections' || true)
        hits=${hits:-0}
        [ "$hits" -eq 0 ] && continue
        err_found=1
        echo "--- $app ($hits recent upstream/socket errors in tail) ---"
        tail -n 2000 "$elog" 2>/dev/null \
            | grep -iE 'upstream timed out|connect\(\) failed|no live upstreams|recv\(\) failed|worker_connections' \
            | tail -3 | sed 's/^/  /'
    done
    [ "$err_found" -eq 0 ] && echo "(no recent upstream errors in tailed nginx error logs)"
fi

if [ "$RUN_AUDIT" -eq 1 ]; then
    run_server_audit
fi

section "DONE"
echo "Stall section: $([ "$RUN_STALL" -eq 1 ] && echo on || echo skipped)"
echo "Audit section: $([ "$RUN_AUDIT" -eq 1 ] && echo on "(N=$AUDIT_LINES)" || echo skipped)"
[ -n "$POOL" ] && echo "Pool filter: $POOL"
