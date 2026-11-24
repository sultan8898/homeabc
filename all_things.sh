#!/usr/bin/env bash

# --- 497: APM Traffic for All Applications (Past 1 Hour) ---
for A in $(ls -l /home/master/applications/ | grep "^d" | awk '{print $NF}'); do
  echo "$A"
  awk 'NR==1 {print substr($NF, 1, length($NF)-1)}' "/home/master/applications/$A/conf/server.nginx" 2>/dev/null
  apm -s "$A" traffic -l 1h 2>/dev/null
done

# --- 498 & 499: Hostname & IP Checks ---
hostname
myip

# --- 500: Exit (Bypassed so script continues execution) ---
# exit

# --- 501: Directory Listing ---
ls

# --- 502: Install Dependencies ---
sudo apt install geoip-bin -y

# --- 503 & 504: Traffic Analysis & Stall Check Scripts ---
curl -sS https://raw.githubusercontent.com/OsamaHilal-CWDO/HealthChecks/Custom-New-Tooling/analyze_cloudways_backend_traffic.py | python3 - --skip-health --progress --days 1
curl -fsSL https://raw.githubusercontent.com/sultan8898/homeabc/refs/heads/cursor/quick-stall-check-a7b8/quick_stall_check.sh | bash

# --- 505: IP Verification ---
myip

# --- 506: Per-App Backend Access Log (Last 1000 lines, Top 20 URIs) ---
for A in $(ls -l /home/master/applications/ | grep "^d" | awk '{print $NF}'); do
  echo -e "\n\n========================================="
  echo "App Directory: $A"
  awk 'NR==1{print "Domain: " substr($NF,1,length($NF)-1)}' "/home/master/applications/$A/conf/server.nginx" 2>/dev/null
  echo "========================================="
  APP_PREFIX=$(grep -oP '[a-zA-Z0-9_]+-[0-9]+-[0-9]+(?=\.cloudwaysapps\.com)' "/home/master/applications/$A/conf/server.nginx" 2>/dev/null | head -n 1)
  if [ -n "$APP_PREFIX" ]; then
    tail -n 1000 "/home/master/applications/$A/logs/backend_${APP_PREFIX}.cloudwaysapps.com.access.log" 2>/dev/null | awk '{print $7}' | cut -d? -f1 | sort | uniq -c | sort -nr | head -n 20
  else
    echo "No valid App Prefix found. Skipping..."
  fi
done

# --- 507: APM wp-cron Traffic Check (Past 6 Hours) ---
for A in $(ls | awk '{print $NF}'); do
  echo "Checking $A"
  sudo /usr/local/sbin/apm php -s "$A" -l 6h 2>/dev/null | grep "wp-cron.php"
done

# --- 508: MySQL Slow Query Summary ---
mysqldumpslow -s t -t 15

# --- 509: Global MySQL Variables/Status & Application Database Audit ---
mysql -e "
SELECT
  VERSION() AS version,
  ROUND(@@innodb_buffer_pool_size/1024/1024/1024, 2) AS bp_gb,
  @@max_connections AS max_conn,
  ROUND(@@tmp_table_size/1024/1024) AS tmp_mb,
  ROUND(@@max_heap_table_size/1024/1024) AS heap_mb,
  @@long_query_time AS lqt,
  @@table_open_cache AS table_open_cache,
  @@innodb_io_capacity AS io_capacity,
  @@innodb_flush_log_at_trx_commit AS flush_trx;

SHOW GLOBAL VARIABLES WHERE Variable_name IN (
  'innodb_buffer_pool_instances',
  'innodb_buffer_pool_size',
  'innodb_log_file_size',
  'innodb_redo_log_capacity',
  'tmp_table_size',
  'max_heap_table_size',
  'max_connections',
  'table_open_cache',
  'innodb_io_capacity',
  'innodb_flush_log_at_trx_commit'
);

SHOW GLOBAL STATUS WHERE Variable_name IN (
  'Uptime',
  'Threads_connected',
  'Max_used_connections',
  'Created_tmp_tables',
  'Created_tmp_disk_tables',
  'Innodb_buffer_pool_reads',
  'Innodb_buffer_pool_read_requests',
  'Table_open_cache_misses',
  'Innodb_log_waits',
  'Innodb_buffer_pool_wait_free',
  'Innodb_checkpoint_age',
  'Innodb_checkpoint_max_age',
  'Select_full_join',
  'Sort_merge_passes'
);

SELECT
  table_schema,
  ROUND(SUM(data_length + index_length) / 1024 / 1024) AS total_mb,
  ROUND(SUM(data_length + index_length) / 1024 / 1024 / 1024, 2) AS total_gb
FROM information_schema.tables
WHERE table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys')
GROUP BY table_schema
ORDER BY total_mb DESC;
" && for app in $(find /home/master/applications -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | grep -vE '^(git|node_modules|wp-content|\..*)$'); do
  echo "=================================================="
  echo ">>> APP / DB: $app"
  echo "=================================================="
  mysql -e "SELECT '$app' AS db, COUNT(*) AS search_rows, SUM(num_results = 0) AS zero_results, SUM(updated_at > NOW() - INTERVAL 30 DAY) AS rows_last_30d FROM \`$app\`.search_query;" 2>/dev/null
  mysql -e "SHOW INDEX FROM \`$app\`.search_query;" 2>/dev/null
  mysql -e "SELECT popularity, COUNT(*) AS n FROM \`$app\`.search_query WHERE updated_at < NOW() - INTERVAL 30 DAY GROUP BY popularity ORDER BY n DESC LIMIT 10;" 2>/dev/null
  mysql -e "SELECT '$app' AS db, COUNT(*) AS rule_price_rows FROM \`$app\`.catalogrule_product_price;" 2>/dev/null
  mysql -e "SHOW INDEX FROM \`$app\`.catalogrule_product_price;" 2>/dev/null
  mysql -N -e "SELECT CONCAT('$app wp_options autoload_kb: ', ROUND(SUM(LENGTH(option_value))/1024)) FROM \`$app\`.wp_options WHERE autoload IN ('yes','on');" 2>/dev/null
done

# --- 510, 511 & 512: Service Logs Analysis Script (MySQL & PHP) ---
curl -s https://raw.githubusercontent.com/sultan8898/homeabc/main/Test.sh | bash -s mysql 2h
curl -s https://raw.githubusercontent.com/sultan8898/homeabc/main/Test.sh | bash -s mysql 21h
curl -s https://raw.githubusercontent.com/sultan8898/homeabc/main/Test.sh | bash -s php 21h

# --- 513: PHP Access Log Check for Status/PID 434937 ---
for app in *; do
  if [ -d "$app/logs" ]; then
    echo "=== $app ==="
    grep -a 434937 "$app/logs/php-app.access.log" 2>/dev/null | awk '{print $6}' | sort | uniq -c | sort -nr
  fi
done

# --- 514: PHP-FPM Resource Usage, Pool Config, Header Check & Free Memory ---
ps -eo rss,args | awk '/php-fpm: pool/{a[$4]+=$1;n[$4]++} END{for(p in a) printf "%s %d workers %d MB\n",p,n[p],a[p]/1024}' | sort -k4 -nr | head -6
grep -rH "pm.max_children" /etc/php/8.2/fpm/ 2>/dev/null | grep -E "wvyjtsmsbq|gagqvtvsdf"
curl -sI https://walk-in-cooler-rental.com | grep -iE "^(server|cf-ray)"
free -m | head -2

# --- 515: PHP Access Log Check for Status/PID 736 ---
for app in *; do
  if [ -d "$app/logs" ]; then
    echo "=== $app ==="
    grep -a 736 "$app/logs/php-app.access.log" 2>/dev/null | awk '{print $6}' | sort | uniq -c | sort -nr
  fi
done

# --- 516 & 517: Known Bot & Crawler Audit Across All Apps ---
BOTS='winhttp-autoproxy-service|facebookexternalhit|gptbot|aiohttp|crawler_eb_germany_2\.0|muckrack|duckduckbot|fidget-spinner-bot|semanticscholarbot|cookiebot|imagesiftbot|awariobot|superfeedr|miss|thesis-research-bot|my-tiny-bot|test-bot|go-http-client|tinytestbot|lunabot|sogou|pandalytics|bytespider|coccocbot-image|webprosbot|inspyder-crawler|hubspot|robot\.alp|yeti|karebot|seekportbot|serpstatbot|monspark|gnowitnewsbot|zoominfobot|barkrowler|turnitin|mediatoolkitbot|grapeshotcrawler|neevabot|criteobot|hyscore\.io|admantx\.com|megaindex|dataforseobot|petalbot|yandex|seekport|blexbot|wallabyupbot|yacybot|linkpadbot|wotbox|woobot|linkdexbot|semrush|exabot|mj12bot|msnbot|haosusospider|slurp|libwww|lwp|damnbot|bbbike|zumbot|tjoosbot|istellabot|liebao|mqq|seznambot|siteexplorer|seznam|aspiegelbot|yealink|vagabondo|vebot|rogerbot|presto|archive\.org_bot|archive\.org|httrack|ccbot|dotbot|blackboard|scrapy|seokicks|amazonbot|ahrefsbot|yandexbot|yandeximages|trendiction(\.de)?|proximic|openai\.com|bingbot|googlebot|applebot|alibaba|meta-externalagent|productbot'

for A in $(ls /home/master/applications/ 2>/dev/null); do
  log_file="/home/master/applications/$A/logs/nginx-app.status.log"
  [ -f "$log_file" ] || continue
  echo -e "\n===== APP: $A ====="
  grep -oiE "$BOTS" "$log_file" | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn
done

# --- 518: Application Disk Usage Breakdown Script ---
curl -fsSL 'https://raw.githubusercontent.com/sultan8898/homeabc/cursor/app-disk-breakdown-c2aa/list_all_apps.py' | python3 - --breakdown --depth 3 --top 20

# --- 519, 520 & 521: Out of Memory (OOM) Inspections ---
dmesg -T | grep -i "Out of memory"
grep "oom" /var/log/syslog 2>/dev/null | awk '{print $7}' | sort | uniq -c | sort -nr
journalctl -b -1 -k 2>/dev/null | grep -i -E "oom|out of memory|killed process"

# --- 522, 523 & 524: System Service Failures ---
grep "Failed" /var/log/syslog 2>/dev/null | awk '{print $7}' | sort | uniq -c | sort -nr
grep "Failed" /var/log/syslog 2>/dev/null | sort | uniq -c | sort -nr
zgrep "Failed" /var/log/syslog.*.gz 2>/dev/null | sort | uniq -c | sort -nr

# --- 525, 526 & 527: Kernel Panics, Bugs, and Critical System Events ---
zgrep -h -i -E "BUG|Oops|kernel panic" /var/log/kern.log* 2>/dev/null
zgrep -E "bug" /var/log/syslog.*.gz 2>/dev/null
zgrep -E "kernel|panic|Oops|critical" /var/log/syslog.1.gz 2>/dev/null

# --- 528: Session History Display ---
history 20 2>/dev/null || true

# --- 529: Imunify360 / ModSecurity Body Limits ---
echo -e "\n=========================================================="
echo " Imunify360 / ModSecurity body limits"
echo "=========================================================="
awk '
  /^SecRequestBodyLimit[[:space:]]/ && FILENAME ~ /body_limit\.conf$/ {
    printf "%s %s\n", $1, $2/1048576 " MB"
  }
  /^SecRequestBodyNoFilesLimit[[:space:]]/ && FILENAME ~ /modsecurity\.conf$/ {
    printf "%s %d MB (%s bytes)\n", $1, $2/1048576, $2
  }
' /etc/imunify360-wafd/modsecurity.d/body_limit.conf \
  /etc/imunify360-wafd/modsecurity.conf 2>/dev/null || echo "ModSecurity body limit configs not found"

# --- 530: Domain DNS vs Server IP (POINTS HERE / ELSEWHERE / NO A RECORD) ---
echo -e "\n=========================================================="
echo " Domain DNS vs this server IP"
echo "=========================================================="
SIP=$(curl -s --max-time 5 ifconfig.me)
echo "Server IP: $SIP"
echo "APP | DOMAIN | RESOLVED IPs | STATUS"
for d in /home/master/applications/*/; do
  app=$(basename "$d")
  f="${d}conf/server.nginx"
  [ -f "$f" ] || continue
  for dom in $(grep -hE '^\s*server_name' "$f" | sed 's/server_name//; s/;//' | tr ' ' '\n' | grep -vE '^\s*$|^_$|^\*|^~' | sort -u); do
    ips=$(dig +short A "$dom" @8.8.8.8 | grep -E '^[0-9.]+$' | tr '\n' ',' | sed 's/,$//')
    if [ -z "$ips" ]; then
      st="NO A RECORD"
    elif echo ",$ips," | grep -q ",$SIP,"; then
      st="POINTS HERE"
    else
      st="ELSEWHERE"
    fi
    printf '%s | %s | %s | %s\n' "$app" "$dom" "${ips:-none}" "$st"
  done
done

# --- 531: Disk, Inodes, Mount Health ---
echo -e "\n=========================================================="
echo " Disk space / inodes / mounts"
echo "=========================================================="
df -hT 2>/dev/null | grep -vE 'tmpfs|devtmpfs|overlay|squashfs'
echo
df -i 2>/dev/null | awk 'NR==1 || $5+0 > 70 {print}'
echo
mount | grep -E 'ro,|,ro' | grep -vE 'tmpfs|proc|sysfs|cgroup|overlay' || echo "No unexpected read-only mounts"

# --- 532: Critical Services Status ---
echo -e "\n=========================================================="
echo " Critical services (nginx / php-fpm / mysql / redis / varnish / imunify)"
echo "=========================================================="
for svc in nginx mysql mariadb redis-server redis varnish varnishd imunify360; do
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 || systemctl status "$svc" >/dev/null 2>&1; then
    printf '%-18s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo n/a)"
  fi
done
systemctl list-units 'php*-fpm.service' --no-legend --no-pager 2>/dev/null | awk '{printf "%-18s %s\n",$1,$3}'
systemctl --failed --no-legend --no-pager 2>/dev/null | head -20 || echo "No failed units"

# --- 533: Swap, Memory Pressure, Open Files ---
echo -e "\n=========================================================="
echo " Memory / swap / open files"
echo "=========================================================="
free -m
echo
swapon --show 2>/dev/null || true
echo "Open files (lsof count approx): $(lsof 2>/dev/null | wc -l)"
echo "File-max: $(cat /proc/sys/fs/file-max 2>/dev/null)  file-nr: $(cat /proc/sys/fs/file-nr 2>/dev/null)"
ulimit -n
ss -s 2>/dev/null | head -8

# --- 534: PHP-FPM max_children Across Installed Versions ---
echo -e "\n=========================================================="
echo " PHP-FPM pm.max_children (all pools)"
echo "=========================================================="
grep -rH "^[[:space:]]*pm.max_children" /etc/php/*/fpm/pool.d/ 2>/dev/null | sort
echo
ps -eo rss,args 2>/dev/null | awk '/php-fpm: pool/{a[$4]+=$1;n[$4]++} END{for(p in a) printf "%s %d workers %d MB\n",p,n[p],a[p]/1024}' | sort -k4 -nr

# --- 535: Redis Snapshot (deep check runs in section 543) ---
echo -e "\n=========================================================="
echo " Redis quick status (deep suite in section 543)"
echo "=========================================================="
if command -v redis-cli >/dev/null 2>&1 && redis-cli ping 2>/dev/null | grep -q PONG; then
  redis-cli INFO memory 2>/dev/null | grep -E 'used_memory_human|maxmemory_human|mem_fragmentation_ratio'
  redis-cli INFO clients 2>/dev/null | grep -E 'connected_clients|blocked_clients'
  redis-cli INFO stats 2>/dev/null | grep -E 'keyspace_hits|keyspace_misses|evicted_keys|expired_keys'
else
  echo "Unauthenticated redis-cli ping failed (auth may be required; see section 543)"
fi

# --- 536: SSL Cert Expiry for Domains Pointing Here ---
echo -e "\n=========================================================="
echo " SSL certificate expiry (domains resolving here)"
echo "=========================================================="
SIP_SSL=$(curl -s --max-time 5 ifconfig.me)
for d in /home/master/applications/*/; do
  f="${d}conf/server.nginx"
  [ -f "$f" ] || continue
  for dom in $(grep -hE '^\s*server_name' "$f" | sed 's/server_name//; s/;//' | tr ' ' '\n' | grep -vE '^\s*$|^_$|^\*|^~|cloudwaysapps\.com' | sort -u); do
    ips=$(dig +short A "$dom" @8.8.8.8 | grep -E '^[0-9.]+$' | tr '\n' ' ')
    echo " $ips " | grep -q " $SIP_SSL " || continue
    expiry=$(echo | timeout 8 openssl s_client -servername "$dom" -connect "${dom}:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$expiry" ]; then
      echo "$dom | expires: $expiry"
    else
      echo "$dom | SSL check failed"
    fi
  done
done

# --- 537: Recent Nginx / PHP Errors Across Apps ---
echo -e "\n=========================================================="
echo " Recent nginx/php errors (last 50 matching lines per app)"
echo "=========================================================="
for d in /home/master/applications/*/; do
  app=$(basename "$d")
  for log in nginx-app.error.log php-app.error.log php-app.slow.log; do
    path="${d}logs/$log"
    [ -f "$path" ] || continue
    hits=$(tail -n 500 "$path" 2>/dev/null | grep -ciE 'error|crit|alert|emerg|fatal|timeout|upstream|max_children|segfault' || true)
    [ "${hits:-0}" -eq 0 ] && continue
    echo -e "\n--- $app / $log ($hits hits in last 500 lines) ---"
    tail -n 500 "$path" 2>/dev/null | grep -iE 'error|crit|alert|emerg|fatal|timeout|upstream|max_children|segfault' | tail -n 20
  done
done

# --- 538: Cron Density / Stuck Cron ---
echo -e "\n=========================================================="
echo " Cron density and stuck wp-cron processes"
echo "=========================================================="
echo "crontab -l (master):"
crontab -l 2>/dev/null | head -40 || echo "(no crontab or not readable)"
echo
echo "Active wp-cron / cron processes:"
ps -eo pid,etime,cmd 2>/dev/null | grep -E 'wp-cron|cron\.php|/usr/sbin/cron' | grep -v grep | head -20
echo
echo "Recent cron syslog lines:"
grep -i cron /var/log/syslog 2>/dev/null | tail -n 15

# --- 539: Listening Ports & Unexpected Listeners ---
echo -e "\n=========================================================="
echo " Listening TCP ports"
echo "=========================================================="
ss -lntup 2>/dev/null | head -60

# --- 540: Time Sync ---
echo -e "\n=========================================================="
echo " Clock / time sync"
echo "=========================================================="
date -u
timedatectl status 2>/dev/null | head -15 || chronyc tracking 2>/dev/null | head -10 || true

# --- 541: Imunify / Malware Quarantine Recent Hits ---
echo -e "\n=========================================================="
echo " Imunify / malware recent signals"
echo "=========================================================="
if command -v imunify360-agent >/dev/null 2>&1; then
  imunify360-agent malware malicious list --limit 10 2>/dev/null || true
  imunify360-agent-remote malware on-demand status 2>/dev/null || true
else
  echo "imunify360-agent not in PATH"
fi
ls -lt /var/imunify360/malware/quarantine 2>/dev/null | head -10 || true

# --- 542: CPU Diagnosis (cpucheck.sh, 60s window) ---
echo -e "\n=========================================================="
echo " CPU diagnosis (cpucheck 60s)"
echo "=========================================================="
cat > /root/cpucheck.sh <<'CPUEOF'
#!/bin/bash
# cpucheck.sh : read-only CPU diagnosis for any Linux server. Changes nothing.
# usage: bash cpucheck.sh [window_seconds=60] [top_n=15]
export LC_ALL=C
WINDOW=${1:-60}; TOPN=${2:-15}
TMP=$(mktemp -d /tmp/cpucheck.XXXXXX); trap 'rm -rf "$TMP"' EXIT
CLK=$(getconf CLK_TCK 2>/dev/null || echo 100)
NCPU=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
FLAGS="$TMP/flags"; : > "$FLAGS"
flag(){ echo "- $*" >> "$FLAGS"; }
hdr(){ printf '\n==== %s ====\n' "$*"; }
gt(){ awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>b+0)}'; }

hdr "0 HOST AND LOAD"
echo "host=$(hostname) utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) kernel=$(uname -r) cpus=$NCPU window=${WINDOW}s"
uptime
command -v lscpu >/dev/null 2>&1 && lscpu 2>/dev/null | grep -E '^(Model name|Hypervisor vendor|Virtualization type|Thread|Core|Socket)'
read -r L1 L5 L15 _ < /proc/loadavg
awk -v a="$L1" -v b="$L5" -v c="$L15" -v n="$NCPU" 'BEGIN{printf "load per CPU: 1m=%.2f 5m=%.2f 15m=%.2f (above 1.00 means runnable work is queuing)\n",a/n,b/n,c/n}'
gt "$(awk -v a="$L15" -v n="$NCPU" 'BEGIN{print a/n}')" 1 && flag "15 minute load per CPU is above 1.0 ($L15 on $NCPU CPUs): sustained queuing before this check"
gt "$(awk -v a="$L5" -v n="$NCPU" 'BEGIN{print a/n}')" 1 && flag "5 minute load per CPU is above 1.0 ($L5 on $NCPU CPUs)"

hdr "1 PRESSURE (PSI) AND CGROUP LIMITS"
if [ -r /proc/pressure/cpu ]; then
  for r in cpu memory io; do [ -r /proc/pressure/$r ] && echo "$r: $(tr '\n' ' ' < /proc/pressure/$r)"; done
  P=$(awk '/^some/{split($2,a,"=");print a[2]}' /proc/pressure/cpu)
  gt "$P" 20 && flag "CPU pressure some avg10=$P (tasks were waiting for a CPU)"
else echo "PSI not available on this kernel"; fi
for f in /sys/fs/cgroup/cpu.stat /sys/fs/cgroup/cpu/cpu.stat; do [ -r "$f" ] && { echo "cgroup $f:"; grep -E 'throttled' "$f"; }; done
[ -r /sys/fs/cgroup/cpu.max ] && echo "cgroup cpu.max: $(cat /sys/fs/cgroup/cpu.max)"

snap(){
  head -1 /proc/stat > "$TMP/$1.total"
  grep '^cpu[0-9]' /proc/stat > "$TMP/$1.cores"
  awk '/^ctxt/{c=$2}/^processes/{p=$2}END{print c,p}' /proc/stat > "$TMP/$1.misc"
  grep -E '^(pgmajfault|pswpin|pswpout|allocstall[a-z_]*|compact_stall) ' /proc/vmstat > "$TMP/$1.vm" 2>/dev/null
  cat /proc/[0-9]*/stat 2>/dev/null | awk '{s=$0; i=index(s,"("); match(s,/\)[^)]*$/); j=RSTART; comm=substr(s,i+1,j-i-1); n=split(substr(s,j+2),f," "); print $1, f[12]+f[13], comm}' > "$TMP/$1.procs"
}

hdr "2 SAMPLING CPU OVER ${WINDOW}s (deltas, not lifetime averages)"
echo "sampling, please wait..."
if command -v vmstat >/dev/null 2>&1; then vmstat 1 "$WINDOW" > "$TMP/vmstat.out" 2>/dev/null & VMPID=$!; fi
snap a; sleep "$WINDOW"; snap b
[ -n "$VMPID" ] && wait "$VMPID" 2>/dev/null

awk 'NR==FNR{for(i=2;i<=11;i++)a[i]=$i;next}{for(i=2;i<=11;i++)d[i]=$i-a[i];t=0;for(i=2;i<=9;i++)t+=d[i]; if(t<1)t=1;
 printf "us=%.1f%% sy=%.1f%% idle=%.1f%% iowait=%.1f%% irq+softirq=%.1f%% steal=%.1f%% (whole machine, all cores)\n",(d[2]+d[3])*100/t,d[4]*100/t,d[5]*100/t,d[6]*100/t,(d[7]+d[8])*100/t,d[9]*100/t;
 printf "%.1f %.1f %.1f %.1f %.1f %.1f %d\n", (d[2]+d[3])*100/t, d[4]*100/t, d[5]*100/t, d[6]*100/t, (d[7]+d[8])*100/t, d[9]*100/t, t > "'"$TMP"'/cpu.vals"}' "$TMP/a.total" "$TMP/b.total" | head -1
read -r US SY ID WA SI ST TT < "$TMP/cpu.vals"
BUSY=$(awk -v i="$ID" -v w="$WA" -v s="$ST" 'BEGIN{printf "%.1f",100-i-w-s}')
echo "busy (user+system+irq, excluding steal and iowait) = ${BUSY}%"
gt "$ST" 5 && flag "CPU steal ${ST}%: the hypervisor is taking CPU from this VM, a host side limit that no tuning inside the server removes"
gt "$WA" 10 && flag "iowait ${WA}%: CPUs are idle waiting on disk"
gt "$SI" 10 && flag "irq+softirq ${SI}%: network or interrupt load (floods, many small packets)"
gt "$SY" 25 && flag "system CPU ${SY}% is high: kernel work (syscalls, swapping, networking, fork churn)"
gt "$BUSY" 85 && flag "machine busy ${BUSY}% over the window"

echo; echo "per core busy% over the window:"
awk 'NR==FNR{for(i=2;i<=11;i++)a[$1,i]=$i;next}{t=0;for(i=2;i<=9;i++){d[i]=$i-a[$1,i];t+=d[i]} if(t<1)t=1; printf "%s=%.0f%% ",$1,100-(d[5]+d[6])*100/t} END{print ""}' "$TMP/a.cores" "$TMP/b.cores" | tee "$TMP/cores.txt"
MAXC=$(tr ' ' '\n' < "$TMP/cores.txt" | sed -E 's/.*=([0-9]+)%/\1/' | grep -E '^[0-9]+$' | sort -n | tail -1)
[ "${MAXC:-0}" -ge 95 ] && gt 60 "$BUSY" && flag "one core is pinned at ${MAXC}% while the machine average is ${BUSY}%: a single threaded bottleneck"

echo; echo "processes (CPU seconds in the window, percent of the whole machine):"
: > "$TMP/names.txt"; : > "$TMP/groups.txt"; : > "$TMP/pids.txt"
awk -v clk="$CLK" -v tt="$TT" -v topn="$TOPN" -v busy="$BUSY" '
function grp(c,   l){ l=tolower(c)
 if(l ~ /^(kworker|ksoftirqd|kswapd|kcompactd|rcu_|migration|khugepaged|jbd2|kthreadd|irq\/|watchdog|writeback|kblockd|ksmd|kcryptd|nvme|scsi_|xfs|ext4)/) return "kernel"
 if(l ~ /(mariadbd|mysqld|postgres|mongod|clickhouse)/) return "database"
 if(l ~ /^(php|lsphp)/) return "php"
 if(l ~ /(nginx|apache2|httpd|varnishd|litespeed|lshttpd|caddy|haproxy)/) return "webserver"
 if(l ~ /(imunify|rustbolit|ai-bolit|aibolit|wafd)/) return "imunify"
 if(l ~ /(redis|memcached|valkey)/) return "cache"
 if(l ~ /^(node|java|python|ruby|gunicorn|uwsgi|dotnet|npm|pm2)/) return "app runtime"
 if(l ~ /(clamd|freshclam|maldet|ossec|fail2ban|wazuh|sensu|monit|collectd|telegraf|datadog|newrelic|zabbix|exporter|cloudways|cw-)/) return "security and monitoring"
 if(l ~ /(rsync|^tar$|gzip|pigz|bzip2|^xz$|zstd|mysqldump|borg|restic|backup)/) return "backup and compress"
 if(l ~ /^(cron|bash|sh|dash|ps|awk|cat|sleep|grep|sed|sort)$/) return "shell and cron"
 return "other" }
NR==FNR{t0[$1]=$2;next}
{ pid=$1; ticks=$2; name=$3; for(i=4;i<=NF;i++)name=name" "$i; d=(pid in t0)?ticks-t0[pid]:ticks; if(d<0)d=0
  if(d>0){ n[name]+=d; g[grp(name)]+=d; sum+=d; print d, pid, name > "'"$TMP"'/pids.txt" } }
END{ if(tt<1)tt=1
 c1="sort -rn | head -" topn " > '"$TMP"'/names.txt"; c2="sort -rn > '"$TMP"'/groups.txt"
 for(k in n) printf "%d\t%s\n", n[k], k | c1
 close(c1)
 for(k in g) printf "%d\t%s\n", g[k], k | c2
 close(c2)
 un=busy*tt/100-sum; if(un<0)un=0
 printf "%.1f\n", un*100/tt > "'"$TMP"'/unattr.txt"
 printf "%.1f\n", sum*100/tt > "'"$TMP"'/attr.txt" }' "$TMP/a.procs" "$TMP/b.procs"
awk -F'\t' -v clk="$CLK" -v tt="$TT" 'BEGIN{if(tt<1)tt=1}{printf "  %-42s %7.1fs %6.1f%%\n",$2,$1/clk,$1*100/tt}' "$TMP/names.txt"
echo; echo "by group (processes that exited inside the window are not counted):"
awk -F'\t' -v clk="$CLK" -v tt="$TT" 'BEGIN{if(tt<1)tt=1}{printf "  %-26s %7.1fs %6.1f%%\n",$2,$1/clk,$1*100/tt}' "$TMP/groups.txt"
UN=$(cat "$TMP/unattr.txt" 2>/dev/null); echo "  unattributed: ${UN}% of the machine (short lived processes that exited inside the window, or kernel time)"
TOPG=$(head -1 "$TMP/groups.txt" 2>/dev/null)
if [ -n "$TOPG" ]; then GN=$(echo "$TOPG" | cut -f2); GP=$(echo "$TOPG" | awk -F'\t' -v tt="$TT" 'BEGIN{if(tt<1)tt=1}{printf "%.1f",$1*100/tt}'); gt "$GP" 30 && flag "group '$GN' used ${GP}% of the machine"; fi
gt "$UN" 25 && flag "${UN}% of CPU is unattributed: look for fork churn (cron, scripts, restart loops) in section 3"

echo; echo "top individual processes (pid, percent of machine, command):"
sort -rn "$TMP/pids.txt" 2>/dev/null | head -10 | while read -r d pid name; do
  a=$(tr '\0\n' '  ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-120); [ -z "$a" ] && a="[$name]"
  awk -v d="$d" -v tt="$TT" -v p="$pid" -v a="$a" 'BEGIN{if(tt<1)tt=1;printf "  pid %-8s %5.1f%%  %s\n",p,d*100/tt,a}'
done

hdr "3 CHURN, SWAP AND RUN QUEUE"
read -r C1 P1 < "$TMP/a.misc"; read -r C2 P2 < "$TMP/b.misc"
FORKS=$(awk -v a="$P1" -v b="$P2" -v w="$WINDOW" 'BEGIN{printf "%.1f",(b-a)/w}')
echo "process creation rate: ${FORKS} forks/s, context switches: $(awk -v a="$C1" -v b="$C2" -v w="$WINDOW" 'BEGIN{printf "%.0f",(b-a)/w}')/s"
gt "$FORKS" 50 && flag "${FORKS} forks/s: process churn (cron jobs, scripts spawning workers, restart loops)"
awk -v w="$WINDOW" 'NR==FNR{a[$1]=$2;next}{d=$2-a[$1]; printf "%s=%.1f/s ",$1,d/w}END{print ""}' "$TMP/a.vm" "$TMP/b.vm" 2>/dev/null | sed 's/^/kernel counters per second: /'
SO=$(awk -v w="$WINDOW" 'NR==FNR{if($1=="pswpout")a=$2;next}{if($1=="pswpout")printf "%.1f",($2-a)/w}' "$TMP/a.vm" "$TMP/b.vm")
AS=$(awk -v w="$WINDOW" 'NR==FNR{if($1 ~ /^allocstall/)a[$1]=$2;next}{if($1 ~ /^allocstall/)s+=($2-a[$1])}END{printf "%.1f",s/w}' "$TMP/a.vm" "$TMP/b.vm")
gt "${SO:-0}" 100 && flag "swap out ${SO} pages/s: memory pressure is turning into CPU and disk work"
gt "${AS:-0}" 1 && flag "direct reclaim stalls ${AS}/s: processes are stalling for memory"
if [ -s "$TMP/vmstat.out" ]; then
  awk 'NR>3 && $1 ~ /^[0-9]+$/ {n++; r+=$1; if($1>mr)mr=$1; b+=$2; if($2>mb)mb=$2; si+=$7; so+=$8; if(mf==""||$4<mf)mf=$4; if($15<30)bu++; if($16>=30)io++; st+=$17}
   END{if(n>0) printf "vmstat %d samples: run queue avg=%.1f max=%d, blocked max=%d, swap in=%.0f out=%.0f KB/s, min free=%d MB, seconds with idle<30%%: %d, seconds with iowait>=30%%: %d, steal avg=%.1f%%\n",n,r/n,mr,mb,si/n,so/n,mf/1024,bu,io,st/n}' "$TMP/vmstat.out" | tee "$TMP/vm.sum"
  RQ=$(sed -E 's/.*max=([0-9]+),.*/\1/' "$TMP/vm.sum"); [ -n "$RQ" ] && [ "$RQ" -gt $((NCPU*3)) ] 2>/dev/null && flag "run queue peaked at $RQ on $NCPU CPUs"
fi
echo; echo "memory:"; free -m 2>/dev/null | head -3
echo "top memory users:"; ps -eo pid,rss,comm --sort=-rss 2>/dev/null | head -6 | awk 'NR==1{print "  "$0;next}{printf "  %s %.0fMB %s\n",$1,$2/1024,$3}'
echo; echo "processes in uninterruptible sleep (D state) right now:"; ps -eo stat,pid,comm,wchan:24 2>/dev/null | awk '$1 ~ /^D/' | head -10
echo; echo "longest cumulative CPU time among running processes:"; ps -eo pid,etime,time,comm --sort=-time 2>/dev/null | head -6

hdr "4 KERNEL AND SERVICE EVENTS"
echo "-- dmesg OOM / hang / throttle (current boot) --"
{ dmesg -T 2>/dev/null || dmesg 2>/dev/null; } | grep -iE 'out of memory|oom-kill|Killed process|soft lockup|hung task|segfault|thermal|throttl|blocked for more than' | tail -20
echo
echo "-- syslog OOM token counts (current syslog) --"
grep -i "oom" /var/log/syslog 2>/dev/null | awk '{print $7}' | sort | uniq -c | sort -nr | head -20
echo
echo "-- previous boot kernel OOM (journalctl -b -1) --"
if command -v journalctl >/dev/null 2>&1; then
  journalctl -b -1 -k --no-pager 2>/dev/null | grep -iE 'oom|out of memory|killed process|oom-kill' | tail -20
else
  echo "journalctl not available"
fi
echo
echo "-- Failed lines in current syslog (token counts) --"
grep "Failed" /var/log/syslog 2>/dev/null | awk '{print $7}' | sort | uniq -c | sort -nr | head -20
echo
echo "-- Failed lines in current syslog (full unique lines, top) --"
grep "Failed" /var/log/syslog 2>/dev/null | sort | uniq -c | sort -nr | head -20
echo
echo "-- Failed lines in rotated syslog.*.gz (top) --"
zgrep "Failed" /var/log/syslog.*.gz 2>/dev/null | sort | uniq -c | sort -nr | head -20
echo
echo "-- kernel BUG / Oops / panic (kern.log*) --"
zgrep -h -iE 'BUG|Oops|kernel panic' /var/log/kern.log* 2>/dev/null | tail -20
echo
echo "-- bug mentions in rotated syslog --"
zgrep -h -E 'bug' /var/log/syslog.*.gz 2>/dev/null | tail -10
echo
echo "-- kernel|panic|Oops|critical in syslog.1.gz --"
zgrep -h -E 'kernel|panic|Oops|critical' /var/log/syslog.1.gz 2>/dev/null | tail -20
FU=$(systemctl --failed --no-legend 2>/dev/null | head -8); [ -n "$FU" ] && { echo "failed units:"; echo "$FU"; }
if command -v journalctl >/dev/null 2>&1; then
  RL=$(journalctl --since "-6 hours" --no-pager -o cat 2>/dev/null | grep -E 'Scheduled restart job|Failed with result' | awk -F': ' '{print $1}' | sort | uniq -c | sort -rn | head -5)
  [ -n "$RL" ] && { echo "units restarting or failing in the last 6 hours:"; echo "$RL"; flag "services are failing or restarting (see section 4), a restart loop burns CPU"; }
fi

hdr "5 WEB AND APPLICATION STACK (only what exists on this server)"
echo "established web connections by remote IP (ports 80, 443, 8080, 8443):"
ss -Htn state established 2>/dev/null | awk '{l=$3;p=$4; if(l ~ /:(80|443|8080|8443)$/){sub(/:[0-9]+$/,"",p); c[p]++}} END{for(k in c)print c[k],k}' | sort -rn | head -8
if pgrep -f 'php-fpm: pool' >/dev/null 2>&1; then
  echo; echo "php-fpm workers per pool right now:"; ps -eo args 2>/dev/null | grep '^php-fpm: pool' | sed 's/php-fpm: pool //' | sort | uniq -c | sort -rn | head -10
  MC=$(cat /var/log/php*fpm*.log /var/log/php*/*fpm*log /var/log/php-fpm/*log 2>/dev/null | grep -c 'max_children')
  echo "max_children warnings in the current php-fpm logs: $MC"
  [ "${MC:-0}" -gt 0 ] && { cat /var/log/php*fpm*.log /var/log/php*/*fpm*log /var/log/php-fpm/*log 2>/dev/null | grep 'max_children' | tail -3; flag "php-fpm logged $MC max_children warnings: the pool filled up at least once"; }
fi
if pgrep -x mariadbd >/dev/null 2>&1 || pgrep -x mysqld >/dev/null 2>&1; then
  echo; echo "database (needs passwordless local access, otherwise this prints an error):"
  mysql --connect-timeout=3 -N -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_running','Threads_connected','Max_used_connections','Slow_queries','Created_tmp_tables','Created_tmp_disk_tables','Aborted_connects')" </dev/null 2>&1 | head -9
  mysql --connect-timeout=3 -N -e "SELECT id,user,time,LEFT(REPLACE(info,CHAR(10),' '),110) FROM information_schema.processlist WHERE command<>'Sleep' AND time>=2 AND id<>CONNECTION_ID() ORDER BY time DESC LIMIT 10" </dev/null 2>&1 | head -12
fi

hdr "6 HISTORY TODAY (needs sysstat, skipped if not collecting)"
if command -v sar >/dev/null 2>&1 && sar -u >/dev/null 2>&1; then
  echo "busiest intervals today (time, busy%, steal%):"
  sar -u 2>/dev/null | awk '$2=="all" && $NF ~ /^[0-9.]+$/ {printf "%s %.1f %.1f\n",$1,100-$NF,$(NF-1)}' | sort -k2 -rn | head -8
else echo "no sysstat history on this server"; fi

hdr "SUMMARY FLAGS (rules of thumb, confirm with the evidence above)"
if [ -s "$FLAGS" ]; then cat "$FLAGS"; else echo "- nothing crossed a threshold during this window (the problem may be intermittent: rerun while it happens, or check section 6)"; fi
echo
echo "Reading notes: this describes only the ${WINDOW}s window above. If load average is far above what was sampled, the heavy period was earlier and the history, logs and kernel events cover it."
CPUEOF
bash /root/cpucheck.sh 60 15 2>&1 | tee /root/cpucheck-$(date -u +%Y%m%dT%H%M%SZ).txt

# --- 542b: OOM / auto-healing / service restart timeline (missing from Osama cpucheck) ---
echo -e "\n=========================================================="
echo " OOM / auto-healing / service restart timeline"
echo "=========================================================="
echo "Generated UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "-- dmesg: Out of memory / Killed process (full match, current boot) --"
dmesg -T 2>/dev/null | grep -iE 'Out of memory|Killed process|oom-kill' | tail -40
echo
echo "-- syslog + rotated: oom-kill / Out of memory / Killed process --"
{ grep -h -iE 'oom-kill|Out of memory|Killed process' /var/log/syslog 2>/dev/null
  zgrep -h -iE 'oom-kill|Out of memory|Killed process' /var/log/syslog.*.gz 2>/dev/null
} | sort -u | tail -60
echo
echo "-- syslog + rotated: mariadb / mysql restart, fail, oom --"
{ grep -h -iE 'mariadb|mysqld' /var/log/syslog 2>/dev/null | grep -iE 'start|stop|fail|oom|kill|restart|Main process'
  zgrep -h -iE 'mariadb|mysqld' /var/log/syslog.*.gz 2>/dev/null | grep -iE 'start|stop|fail|oom|kill|restart|Main process'
} | sort -u | tail -40
echo
echo "-- syslog + rotated: nginx / php-fpm / redis / varnish / apache restart or fail --"
{ grep -h -iE 'nginx\.service|php[0-9.]*-fpm|redis-server|varnish|apache2' /var/log/syslog 2>/dev/null | grep -iE 'start|stop|fail|restart|Main process|exited'
  zgrep -h -iE 'nginx\.service|php[0-9.]*-fpm|redis-server|varnish|apache2' /var/log/syslog.*.gz 2>/dev/null | grep -iE 'start|stop|fail|restart|Main process|exited'
} | sort -u | tail -40
echo
echo "-- syslog + rotated: monit / auto-healing / imunify agent fail --"
{ grep -h -iE 'monit|auto.?heal|imunify360-agent|Failed to start|Failed with result' /var/log/syslog 2>/dev/null
  zgrep -h -iE 'monit|auto.?heal|imunify360-agent|Failed to start|Failed with result' /var/log/syslog.*.gz 2>/dev/null
} | grep -iE 'monit|heal|imunify|mariadb|mysql|nginx|php|redis|varnish|oom|kill' | sort -u | tail -40
echo
echo "-- journalctl previous boot (-b -1) OOM / killed process --"
journalctl -b -1 -k --no-pager 2>/dev/null | grep -iE 'oom|out of memory|killed process|oom-kill' | tail -30
echo
echo "-- MySQL Max_used_connections / Threads snapshot (live) --"
mysql --connect-timeout=3 -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Max_used_connections','Threads_connected','Threads_running','Aborted_connects','Uptime');" 2>/dev/null
echo
echo "-- Memory / swap snapshot --"
free -m
echo "OOM / auto-healing timeline section done."

# --- 543: Redis deep diagnosis (auth discovery + full suite) ---
echo -e "\n=========================================================="
echo " Redis deep diagnosis"
echo "=========================================================="

rcli() { redis-cli --no-auth-warning "$@"; }

discover_redis_auth() {
  REDIS_HOST="127.0.0.1"
  REDIS_PORT="6379"
  REDIS_PASS=""
  REDIS_USER=""
  REDIS_AUTH_SRC="none"

  if rcli ping 2>/dev/null | grep -q PONG; then
    REDIS_AUTH_SRC="nopass"
    return 0
  fi

  # requirepass / ACL from redis.conf variants
  for conf in /etc/redis/redis.conf /etc/redis.conf /etc/redis/redis-server.conf; do
    [ -f "$conf" ] || continue
    rp=$(awk '/^[[:space:]]*requirepass[[:space:]]+/ {print $2; exit}' "$conf" | tr -d '"' | tr -d "'")
    if [ -n "$rp" ]; then
      if rcli -a "$rp" ping 2>/dev/null | grep -q PONG; then
        REDIS_PASS="$rp"
        REDIS_AUTH_SRC="redis.conf:$conf"
        return 0
      fi
    fi
  done

  # Cloudways / Object Cache Pro: scrape WP_REDIS_CONFIG from wp-config.php
  while IFS= read -r cfg; do
    [ -f "$cfg" ] || continue
    block=$(awk '
      /WP_REDIS_CONFIG/ {inb=1}
      inb {print}
      inb && /\];/ {exit}
    ' "$cfg" 2>/dev/null)
    [ -n "$block" ] || continue

    h=$(printf '%s\n' "$block" | grep -oE "'host'[[:space:]]*=>[[:space:]]*'[^']+'" | head -1 | sed -E "s/.*=>[[:space:]]*'([^']+)'.*/\1/")
    p=$(printf '%s\n' "$block" | grep -oE "'port'[[:space:]]*=>[[:space:]]*[0-9]+" | head -1 | grep -oE '[0-9]+$')
    pw=$(printf '%s\n' "$block" | grep -oE "'password'[[:space:]]*=>[[:space:]]*'[^']*'" | head -1 | sed -E "s/.*=>[[:space:]]*'([^']*)'.*/\1/")
    [ -z "$pw" ] && pw=$(printf '%s\n' "$block" | grep -oE '"password"[[:space:]]*=>[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*=>[[:space:]]*"([^"]*)".*/\1/')
    u=$(printf '%s\n' "$block" | grep -oE "'username'[[:space:]]*=>[[:space:]]*'[^']*'" | head -1 | sed -E "s/.*=>[[:space:]]*'([^']*)'.*/\1/")
    [ -z "$u" ] && u=$(printf '%s\n' "$block" | grep -oE "'user'[[:space:]]*=>[[:space:]]*'[^']*'" | head -1 | sed -E "s/.*=>[[:space:]]*'([^']*)'.*/\1/")

    # also catch classic defines
    [ -z "$pw" ] && pw=$(grep -oE "define\(\s*'WP_REDIS_PASSWORD'\s*,\s*'[^']*'" "$cfg" 2>/dev/null | head -1 | sed -E "s/.*,\s*'([^']*)'.*/\1/")
    [ -z "$h" ] && h=$(grep -oE "define\(\s*'WP_REDIS_HOST'\s*,\s*'[^']*'" "$cfg" 2>/dev/null | head -1 | sed -E "s/.*,\s*'([^']*)'.*/\1/")
    [ -z "$p" ] && p=$(grep -oE "define\(\s*'WP_REDIS_PORT'\s*,\s*[0-9]+" "$cfg" 2>/dev/null | head -1 | grep -oE '[0-9]+$')

    [ -n "$h" ] && REDIS_HOST="$h"
    [ -n "$p" ] && REDIS_PORT="$p"

    if [ -n "$pw" ]; then
      if [ -n "$u" ]; then
        if rcli -h "$REDIS_HOST" -p "$REDIS_PORT" --user "$u" -a "$pw" ping 2>/dev/null | grep -q PONG; then
          REDIS_PASS="$pw"; REDIS_USER="$u"; REDIS_AUTH_SRC="wp-config:$cfg"
          return 0
        fi
      fi
      if rcli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$pw" ping 2>/dev/null | grep -q PONG; then
        REDIS_PASS="$pw"; REDIS_AUTH_SRC="wp-config:$cfg"
        return 0
      fi
    fi
  done < <(find /home/master/applications -maxdepth 4 -type f -name wp-config.php 2>/dev/null)

  return 1
}

rc() {
  # authenticated redis-cli wrapper using discovered creds
  if [ -n "$REDIS_USER" ] && [ -n "$REDIS_PASS" ]; then
    rcli -h "${REDIS_HOST:-127.0.0.1}" -p "${REDIS_PORT:-6379}" --user "$REDIS_USER" -a "$REDIS_PASS" "$@"
  elif [ -n "$REDIS_PASS" ]; then
    rcli -h "${REDIS_HOST:-127.0.0.1}" -p "${REDIS_PORT:-6379}" -a "$REDIS_PASS" "$@"
  else
    rcli -h "${REDIS_HOST:-127.0.0.1}" -p "${REDIS_PORT:-6379}" "$@"
  fi
}

echo "===== REDIS HOST SNAPSHOT ====="
uptime
nproc
free -m
vmstat 1 5
top -b -n1 -o %CPU 2>/dev/null | head -n 25
ps -eo pid,user,%cpu,%mem,rss,etime,cmd --sort=-%cpu 2>/dev/null | head -n 15
ps -C redis-server -o pid,user,%cpu,%mem,rss,etime,nlwp,cmd 2>/dev/null
RPIDS=$(pgrep -d, redis-server 2>/dev/null)
if [ -n "$RPIDS" ]; then
  top -b -H -n1 -p "$RPIDS" 2>/dev/null | head -n 20
  if command -v pidstat >/dev/null 2>&1; then
    pidstat -u -p "$RPIDS" 1 5 2>/dev/null
  else
    echo "pidstat not installed"
  fi
fi
systemctl status redis-server --no-pager 2>/dev/null || systemctl status redis --no-pager 2>/dev/null || true
dpkg -l 2>/dev/null | grep -i redis || true

echo
echo "===== REDIS AUTH DISCOVERY ====="
if discover_redis_auth; then
  echo "Auth OK via: $REDIS_AUTH_SRC  host=$REDIS_HOST port=$REDIS_PORT user=${REDIS_USER:-default}"
else
  echo "Could not authenticate to Redis (tried nopass, redis.conf requirepass, wp-config WP_REDIS_CONFIG)"
fi

if rc ping 2>/dev/null | grep -q PONG; then
  echo
  echo "===== REDIS INFO / CONFIG / SLOWLOG ====="
  rc INFO server 2>/dev/null | grep -E 'redis_version|uptime_in_seconds|process_id|config_file|hz|io_threads'
  rc INFO cpu 2>/dev/null
  rc INFO memory 2>/dev/null | grep -E 'used_memory_human|used_memory_rss_human|used_memory_peak_human|used_memory_startup|maxmemory_human|maxmemory_policy|mem_fragmentation_ratio'
  rc INFO stats 2>/dev/null | grep -E 'instantaneous_ops_per_sec|total_commands_processed|rejected_connections|evicted_keys|expired_keys|keyspace_hits|keyspace_misses|eviction_exceeded_time'
  rc INFO clients 2>/dev/null
  rc INFO persistence 2>/dev/null | grep -E 'loading|rdb_bgsave_in_progress|rdb_last_bgsave_status|aof_enabled|aof_rewrite_in_progress'
  rc INFO errorstats 2>/dev/null
  rc INFO commandstats 2>/dev/null | awk -F'[=,]' '/cmdstat/{print $4, $0}' | sort -nr | head -n 15
  echo "keyspace lines: $(rc INFO keyspace 2>/dev/null | wc -l)"
  rc INFO keyspace 2>/dev/null | head -n 20
  rc CONFIG GET maxmemory 2>/dev/null
  rc CONFIG GET maxmemory-policy 2>/dev/null
  rc CONFIG GET databases 2>/dev/null
  rc CONFIG GET hz 2>/dev/null
  rc CONFIG GET save 2>/dev/null
  rc CONFIG GET appendonly 2>/dev/null
  echo "client list count: $(rc CLIENT LIST 2>/dev/null | wc -l)"
  rc CLIENT LIST 2>/dev/null | grep -o 'cmd=[a-z|]*' | sort | uniq -c | sort -nr | head -n 10
  echo "slowlog len: $(rc SLOWLOG LEN 2>/dev/null)"
  rc SLOWLOG GET 20 2>/dev/null
  rc LATENCY LATEST 2>/dev/null
  rc LATENCY DOCTOR 2>/dev/null
  timeout 10 redis-cli --no-auth-warning ${REDIS_PASS:+-a "$REDIS_PASS"} ${REDIS_USER:+--user "$REDIS_USER"} -h "${REDIS_HOST:-127.0.0.1}" -p "${REDIS_PORT:-6379}" --stat 2>/dev/null || true
  timeout 10 redis-cli --no-auth-warning ${REDIS_PASS:+-a "$REDIS_PASS"} ${REDIS_USER:+--user "$REDIS_USER"} -h "${REDIS_HOST:-127.0.0.1}" -p "${REDIS_PORT:-6379}" --latency 2>/dev/null || true

  echo
  echo "===== REDIS EXTRA HEALTH FLAGS ====="
  MEM_FRAG=$(rc INFO memory 2>/dev/null | awk -F: '/mem_fragmentation_ratio/{gsub(/\r/,"",$2); print $2}')
  MAXMEM=$(rc CONFIG GET maxmemory 2>/dev/null | awk 'NR==2{print}')
  USEDBYTES=$(rc INFO memory 2>/dev/null | awk -F: '/^used_memory:/{gsub(/\r/,"",$2); print $2}')
  OPS=$(rc INFO stats 2>/dev/null | awk -F: '/instantaneous_ops_per_sec/{gsub(/\r/,"",$2); print $2}')
  EVICT=$(rc INFO stats 2>/dev/null | awk -F: '/^evicted_keys:/{gsub(/\r/,"",$2); print $2}')
  REJECT=$(rc INFO stats 2>/dev/null | awk -F: '/rejected_connections/{gsub(/\r/,"",$2); print $2}')
  HITS=$(rc INFO stats 2>/dev/null | awk -F: '/keyspace_hits/{gsub(/\r/,"",$2); print $2}')
  MISSES=$(rc INFO stats 2>/dev/null | awk -F: '/keyspace_misses/{gsub(/\r/,"",$2); print $2}')
  echo "fragmentation_ratio=$MEM_FRAG ops/s=$OPS evicted_keys=$EVICT rejected_connections=$REJECT used_memory=$USEDBYTES maxmemory=$MAXMEM"
  awk -v h="$HITS" -v m="$MISSES" 'BEGIN{t=h+m; if(t>0) printf "hit_rate=%.2f%% (%d hits / %d lookups)\n", h*100/t, h, t; else print "hit_rate=n/a"}'
  awk -v f="$MEM_FRAG" 'BEGIN{if(f+0>0 && (f+0<1.0 || f+0>2.5)) print "FLAG: mem_fragmentation_ratio unusual (" f ")"}'
  awk -v u="$USEDBYTES" -v m="$MAXMEM" 'BEGIN{if(m+0>0 && u+0>0 && u/m>0.90) printf "FLAG: used_memory is %.1f%% of maxmemory\n", u*100/m}'
  [ "${EVICT:-0}" -gt 0 ] 2>/dev/null && echo "FLAG: evicted_keys=$EVICT (maxmemory pressure / eviction happening)"
  [ "${REJECT:-0}" -gt 0 ] 2>/dev/null && echo "FLAG: rejected_connections=$REJECT"

  echo
  echo "===== PER-APP REDIS DB MAPPING (from wp-config) ====="
  printf '%-20s %-10s %-8s %-s\n' "APP" "DATABASE" "KEYS" "CONFIG"
  for cfg in $(find /home/master/applications -maxdepth 4 -type f -name wp-config.php 2>/dev/null); do
    app=$(echo "$cfg" | awk -F/ '{for(i=1;i<=NF;i++) if($i=="applications"){print $(i+1); exit}}')
    db=$(awk '/WP_REDIS_CONFIG/{inb=1} inb && /database/{match($0,/[0-9]+/); if(RSTART){print substr($0,RSTART,RLENGTH); exit}} inb && /\];/{exit}' "$cfg" 2>/dev/null)
    [ -z "$db" ] && continue
    keys=$(rc -n "$db" DBSIZE 2>/dev/null | awk '{print $NF}')
    printf '%-20s %-10s %-8s %-s\n' "$app" "$db" "${keys:-?}" "$cfg"
  done

  echo
  echo "===== BIGGEST REDIS KEYS (SCAN sample, db0 + mapped dbs) ====="
  for db in 0 $(for cfg in $(find /home/master/applications -maxdepth 4 -name wp-config.php 2>/dev/null); do awk '/WP_REDIS_CONFIG/{inb=1} inb && /database/{match($0,/[0-9]+/); if(RSTART){print substr($0,RSTART,RLENGTH); exit}} inb && /\];/{exit}' "$cfg"; done | sort -nu | head -10); do
    echo "-- DB $db sample --"
    rc -n "$db" --scan --count 200 2>/dev/null | head -n 30 | while read -r k; do
      [ -z "$k" ] && continue
      sz=$(rc -n "$db" MEMORY USAGE "$k" 2>/dev/null)
      echo "${sz:-0} $k"
    done | sort -nr | head -n 8
  done
else
  echo "Skipping INFO/CONFIG suite: Redis not authenticated"
fi

echo
echo "===== REDIS LOGS / OBJECTCACHE / MONIT / SAR ====="
journalctl -u redis-server --since "-6h" --no-pager 2>/dev/null | tail -n 50
tail -n 50 /var/log/redis/*.log 2>/dev/null
grep -iE 'objectcache|OOM command' /var/log/syslog 2>/dev/null | tail -n 20
grep -i redis /var/log/monit.log 2>/dev/null | tail -n 20
if command -v sar >/dev/null 2>&1; then
  sar -u 2>/dev/null | tail -n 30 || echo "sar history unavailable (sysstat data collecting may be disabled)"
else
  echo "sar not installed"
fi

# --- 544: Varnish deep diagnosis ---
echo -e "\n=========================================================="
echo " Varnish deep diagnosis"
echo "=========================================================="

# Prefer a live domain that points to this server; fall back to first non-cloudwaysapps server_name
SIP_V=$(curl -s --max-time 5 ifconfig.me)
DOMAIN=""
for d in /home/master/applications/*/; do
  f="${d}conf/server.nginx"
  [ -f "$f" ] || continue
  for dom in $(grep -hE '^\s*server_name' "$f" | sed 's/server_name//; s/;//' | tr ' ' '\n' | grep -vE '^\s*$|^_$|^\*|^~|cloudwaysapps\.com' | sort -u); do
    ips=$(dig +short A "$dom" @8.8.8.8 | grep -E '^[0-9.]+$' | tr '\n' ' ')
    if echo " $ips " | grep -q " $SIP_V "; then
      DOMAIN="$dom"
      break 2
    fi
  done
done
if [ -z "$DOMAIN" ]; then
  DOMAIN=$(grep -hE '^\s*server_name' /home/master/applications/*/conf/server.nginx 2>/dev/null | sed 's/server_name//; s/;//' | tr ' ' '\n' | grep -vE '^\s*$|^_$|^\*|^~|cloudwaysapps\.com' | head -1)
fi
DOMAIN=${DOMAIN:-example.com}
echo "Using DOMAIN=$DOMAIN for external response tests"

T=/tmp/vchk.$$
{
echo "===== 1. VERSION / SERVICE / STORAGE ====="
varnishd -V 2>&1 | head -1
systemctl is-active varnish 2>/dev/null
systemctl show varnish -p ActiveEnterTimestamp 2>/dev/null
ps -eo pid,etime,args | grep '[v]arnishd' | head -3
echo; echo "===== 2. VCL / BACKEND / KEY PARAMS ====="
varnishadm vcl.list 2>&1
varnishadm backend.list 2>&1
varnishadm param.show default_ttl 2>&1 | head -3
varnishadm param.show default_grace 2>&1 | head -3
varnishadm param.show thread_pool_min 2>&1 | head -2
varnishadm param.show thread_pool_max 2>&1 | head -2

echo; echo "===== 3. COUNTERS (since varnish start) ====="
varnishstat -1 -f MAIN.uptime -f MAIN.client_req -f MAIN.cache_hit -f MAIN.cache_miss -f MAIN.cache_hitpass -f MAIN.cache_hitmiss -f MAIN.s_pass -f MAIN.s_synth -f MAIN.n_object -f MAIN.n_expired -f MAIN.n_lru_nuked -f MAIN.backend_fail -f MAIN.backend_busy -f MAIN.sess_dropped -f MAIN.threads_limited -f 'SMA.*.g_bytes' -f 'SMA.*.g_space' 2>&1
varnishstat -1 2>/dev/null | awk '$1=="MAIN.cache_hit"{h=$2} $1=="MAIN.cache_miss"{m=$2} $1=="MAIN.cache_hitpass"{p=$2} $1=="MAIN.client_req"{r=$2} $1=="MAIN.n_lru_nuked"{n=$2} $1=="MAIN.backend_fail"{bf=$2} $1=="MAIN.threads_limited"{tl=$2} END{printf "hit=%d miss=%d hitpass=%d client_req=%d lru_nuked=%d backend_fail=%d threads_limited=%d | hit%%_of_lookups=%.1f | hit%%_of_all_reqs=%.1f\n",h,m,p,r,n,bf,tl,(h+m+p)?h*100/(h+m+p):0,r?h*100/r:0}'

echo; echo "===== 4. RECENT TRAFFIC BY HANDLING (log buffer window only) ====="
timeout 60 varnishncsa -d -F '%t' 2>/dev/null | sed -n '1p;$p' | sed 's/^/window edge: /'
timeout 60 varnishncsa -d -F '%{Varnish:handling}x' 2>/dev/null | sort | uniq -c | sort -rn

echo; echo "===== 5. PURGE ACTIVITY (log buffer window) ====="
timeout 60 varnishncsa -d -q 'ReqMethod eq "PURGE" or ReqMethod eq "URLPURGE"' -F '%t|%m|%U' > $T.purge 2>/dev/null
echo "by method:"; cut -d'|' -f2 $T.purge 2>/dev/null | sort | uniq -c
echo "PURGE method (full domain wipe on Cloudways VCL): $(grep -c '|PURGE|' $T.purge 2>/dev/null || echo 0)"
echo "window: $(head -1 $T.purge 2>/dev/null | cut -d'|' -f1)  ->  $(tail -1 $T.purge 2>/dev/null | cut -d'|' -f1)"
echo "busiest minutes:"; cut -d'|' -f1 $T.purge 2>/dev/null | cut -c2-18 | sort | uniq -c | sort -rn | head -8
echo "top purged URLs:"; cut -d'|' -f2- $T.purge 2>/dev/null | sort | uniq -c | sort -rn | head -15

echo; echo "===== 6. MISS / PASS ANALYSIS (GET, non-static) ====="
timeout 60 varnishncsa -d -q 'ReqMethod eq "GET"' -F "%{Varnish:handling}x"$'\t'"%U%q"$'\t'"%{Cookie}i" 2>/dev/null \
 | awk -F'\t' '$2 !~ /\.(css|js|png|jpe?g|gif|webp|svg|woff2?|ico|map)(\?|$)/' > $T.get
awk -F'\t' '{n[$1]++; t++; q=($2 ~ /\?/); tr=($2 ~ /[?&](utm_[a-z]+|fbclid|gclid|msclkid|ttclid|mc_cid|mc_eid)=/); ck=($3!="-" && $3!=""); wc=($3 ~ /woocommerce_items_in_cart|wp_woocommerce_session|woocommerce_cart_hash|wordpress_logged_in/); if(q)nq[$1]++; if(tr)ntr[$1]++; if(ck)nck[$1]++; if(wc)nwc[$1]++}
END{printf "%-8s %8s %10s %10s %10s %10s\n","handling","count","with_qs","w/tracking","w/cookie","w/woo_login"; for(k in n)printf "%-8s %8d %10d %10d %10d %10d\n",k,n[k],nq[k],ntr[k],nck[k],nwc[k]; print "total non-static GET:",t}' $T.get
echo "top MISS URLs:"; awk -F'\t' '$1=="miss"{print $2}' $T.get | sort | uniq -c | sort -rn | head -15
echo "top PASS URLs:"; awk -F'\t' '$1=="pass"{print $2}' $T.get | sort | uniq -c | sort -rn | head -15

echo; echo "===== 7. CUSTOM VCL FILES ON SERVER ====="
for f in $(find /home -maxdepth 4 -type f \( -name custom-recv.vcl -o -name custom-resp.vcl \) -size +0 2>/dev/null); do echo "--- $f"; head -40 "$f"; done

echo; echo "===== 8. BREEZE SETTINGS (all apps) ====="
for f in $(find /home -maxdepth 7 -path '*wp-content/breeze-config/breeze-config.php' 2>/dev/null); do echo "--- $f"; grep -E "auto-purge-varnish|breeze-b-ttl|breeze-mobile-separate|breeze-cache-warmup-enabled|woocommerce_geolocation_ajax" "$f"; grep -A3 "cached-query-strings" "$f" | head -4; done

echo; echo "===== 9. EXTERNAL RESPONSE TEST: $DOMAIN ====="
H='^(HTTP|server|x-cache|x-varnish|age|cache-control|set-cookie|vary|via|cf-cache-status|x-cache-status)'
for U in "https://$DOMAIN/" "https://$DOMAIN/" "https://$DOMAIN/?utm_source=chk&fbclid=chk123"; do echo "--- GET $U"; curl -sI -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' --max-time 15 "$U" | grep -iE "$H"; done

echo; echo "===== 10. EXTRA VARNISH HEALTH FLAGS ====="
varnishstat -1 2>/dev/null | awk '
  $1=="MAIN.cache_hit"{h=$2}
  $1=="MAIN.cache_miss"{m=$2}
  $1=="MAIN.n_lru_nuked"{n=$2}
  $1=="MAIN.backend_fail"{bf=$2}
  $1=="MAIN.backend_busy"{bb=$2}
  $1=="MAIN.threads_limited"{tl=$2}
  $1=="MAIN.sess_dropped"{sd=$2}
  $1=="MAIN.client_req"{r=$2}
  END{
    lookups=h+m
    if(lookups>0 && h*100/lookups < 50) printf "FLAG: hit rate of lookups is low (%.1f%%)\n", h*100/lookups
    if(n+0>0) printf "FLAG: LRU nuked objects=%d (storage pressure / undersized cache)\n", n
    if(bf+0>0) printf "FLAG: backend_fail=%d\n", bf
    if(bb+0>0) printf "FLAG: backend_busy=%d\n", bb
    if(tl+0>0) printf "FLAG: threads_limited=%d\n", tl
    if(sd+0>0) printf "FLAG: sess_dropped=%d\n", sd
    if(r+0==0) print "FLAG: no client_req counted yet"
  }'
echo "Varnish listen sockets:"
ss -lntp 2>/dev/null | grep -i varnish || ss -lntp 2>/dev/null | grep -E ':(80|6081|8080)\s'
echo "Recent varnish syslog:"
journalctl -u varnish --since "-6h" --no-pager 2>/dev/null | tail -n 30
grep -i varnish /var/log/syslog 2>/dev/null | tail -n 20
} 2>&1 | tee /tmp/varnish_check_$(date +%F_%H%M).txt
rm -f $T.purge $T.get

# --- 545: Hybrid stack deep checks (nginx / apache / php / mysql / redis / varnish) ---
echo -e "\n=========================================================="
echo " Hybrid stack deep checks (nginx/apache/php/mysql/redis/varnish)"
echo "=========================================================="

echo "===== A. APPLICATION FACTS / STACK DECLARATION ====="
if [ -f /etc/ansible/facts.d/applications.fact ]; then
  cat /etc/ansible/facts.d/applications.fact
else
  echo "applications.fact not found"
fi
echo
echo "Listeners (port -> process):"
ss -lntp 2>/dev/null | awk 'NR==1 || /:(80|443|8080|8081|8082|8085|6081|6379|3306)\s/'
echo
echo "Process presence:"
for p in nginx apache2 httpd varnishd redis-server mariadbd mysqld php-fpm; do
  c=$(pgrep -c "$p" 2>/dev/null || echo 0)
  printf '  %-14s %s\n' "$p" "$c"
done

echo
echo "===== B. NGINX ====="
nginx -t 2>&1 | tail -n 5
nginx -V 2>&1 | tr ' ' '\n' | grep -E 'nginx/|http_v2|http_ssl|with-http' | head -20
systemctl is-active nginx 2>/dev/null
echo "worker_processes / connections:"
grep -rE '^\s*(worker_processes|worker_connections|keepalive_timeout|client_max_body_size|proxy_read_timeout|fastcgi_read_timeout)' /etc/nginx/ 2>/dev/null | grep -vE 'modules|sites-enabled' | head -40
echo "top nginx error patterns (all apps, last 500 lines each):"
for f in /home/master/applications/*/logs/nginx-app.error.log; do
  [ -f "$f" ] || continue
  app=$(echo "$f" | awk -F/ '{print $(NF-2)}')
  hits=$(tail -n 500 "$f" 2>/dev/null | grep -ciE 'upstream timed out|connect\(\) failed|no live upstreams|recv\(\) failed|FastCGI|Primary script unknown' || true)
  [ "${hits:-0}" -eq 0 ] && continue
  echo "--- $app ($hits) ---"
  tail -n 500 "$f" 2>/dev/null | grep -iE 'upstream timed out|connect\(\) failed|no live upstreams|recv\(\) failed|FastCGI|Primary script unknown' | sed 's/[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+/x.x.x.x/g' | sort | uniq -c | sort -nr | head -8
done
echo "status code mix (nginx-app.status.log, last 2000/app):"
for f in /home/master/applications/*/logs/nginx-app.status.log; do
  [ -f "$f" ] || continue
  app=$(echo "$f" | awk -F/ '{print $(NF-2)}')
  echo -n "$app: "
  tail -n 2000 "$f" 2>/dev/null | awk '{print $9}' | grep -E '^[0-9]{3}$' | sort | uniq -c | sort -nr | tr '\n' ' '
  echo
done
echo "uncacheable Woo/AJAX pressure (backend access, last 3000/app):"
for d in /home/master/applications/*/; do
  app=$(basename "$d")
  blog=$(ls "$d"logs/backend_*.access.log 2>/dev/null | head -1)
  [ -f "$blog" ] || continue
  echo "--- $app ---"
  tail -n 3000 "$blog" 2>/dev/null | awk '{print $7}' | cut -d? -f1 | grep -E 'admin-ajax|wc-ajax|wp-cron|wp-json|checkout|cart' | sort | uniq -c | sort -nr | head -12
  echo -n "wc-ajax actions: "
  tail -n 3000 "$blog" 2>/dev/null | grep -oE 'wc-ajax=[^& ]+' | sort | uniq -c | sort -nr | head -8 | tr '\n' ' '
  echo
  echo -n "admin-ajax actions: "
  tail -n 3000 "$blog" 2>/dev/null | grep 'admin-ajax.php' | grep -oE 'action=[^& ]+' | sort | uniq -c | sort -nr | head -10 | tr '\n' ' '
  echo
done

echo
echo "===== C. APACHE (hybrid backends) ====="
apache2ctl -v 2>/dev/null | head -2 || httpd -v 2>/dev/null | head -2
systemctl is-active apache2 2>/dev/null || systemctl is-active httpd 2>/dev/null
apache2ctl -S 2>/dev/null | head -40 || true
echo "mpm / server limits:"
apache2ctl -M 2>/dev/null | grep -iE 'mpm|proxy|fcgi|http2' || true
grep -rE '^\s*(MaxRequestWorkers|ServerLimit|ThreadsPerChild|MaxClients|KeepAliveTimeout|Timeout|ProxyTimeout)' /etc/apache2/ 2>/dev/null | head -30
echo "apache error highlights:"
for f in /home/master/applications/*/logs/apache_*.error.log /var/log/apache2/*error*.log; do
  [ -f "$f" ] || continue
  echo "--- $f ---"
  tail -n 300 "$f" 2>/dev/null | grep -iE 'timeout|proxy_fcgi|AH0|server reached|MaxRequestWorkers|segfault|oom' | tail -n 12
done
echo "apache scoreboard / busy workers (if server-status enabled locally):"
curl -s --max-time 3 http://127.0.0.1:8081/server-status?auto 2>/dev/null | grep -E '^(BusyWorkers|IdleWorkers|Scoreboard|ReqPerSec|BytesPerSec)' || echo "server-status not available on :8081"

echo
echo "===== D. PHP-FPM ====="
echo "installed PHP versions / masters:"
ps -eo pid,etime,cmd 2>/dev/null | grep 'php-fpm: master' | grep -v grep
echo
for conf in /etc/php/*/fpm/pool.d/*.conf; do
  [ -f "$conf" ] || continue
  pool=$(basename "$conf" .conf)
  [ "$pool" = "www" ] || [ "$pool" = "cloudways" ] || [[ "$pool" == placeholder* ]] || [[ "$pool" == *-* ]] || continue
  echo "--- $conf ---"
  grep -E '^\s*(\[|user|group|listen|pm\.|request_terminate_timeout|slowlog|request_slowlog_timeout)' "$conf" 2>/dev/null | head -30
done
echo
echo "max_children warnings (all php fpm logs):"
grep -h 'max_children' /var/log/php*-fpm.log /var/log/php*/*fpm*.log /home/master/applications/*/logs/php-app.error.log 2>/dev/null | tail -n 30
echo
echo "slow-log hot plugins/scripts (tail 2000 per app):"
for f in /home/master/applications/*/logs/php-app.slow.log; do
  [ -f "$f" ] || continue
  app=$(echo "$f" | awk -F/ '{print $(NF-2)}')
  echo "--- $app ---"
  echo "entry scripts:"
  grep -E 'script_filename|^\[' "$f" 2>/dev/null | tail -n 2000 | grep script_filename | sed 's/.*script_filename = //' | sort | uniq -c | sort -nr | head -8
  echo "plugin/theme frames:"
  tail -n 2000 "$f" 2>/dev/null | grep -oE 'wp-content/(plugins|themes)/[^/]+' | sort | uniq -c | sort -nr | head -10
  echo "blocking calls:"
  tail -n 2000 "$f" 2>/dev/null | grep -oE '(sleep|curl_exec|mysqli_query|PDOStatement::execute|file_get_contents|wp_remote_)\(' | sort | uniq -c | sort -nr | head -10
done
echo
echo "OPcache / runtime per live pool socket (best effort):"
for sock in /var/run/fpm-*.sock /run/php/php*-fpm.sock; do
  [ -S "$sock" ] || continue
  echo "socket $sock present"
done
php -v 2>/dev/null | head -2
php -i 2>/dev/null | grep -E '^(memory_limit|max_execution_time|opcache\.(memory_consumption|revalidate_freq|enable)|realpath_cache_size)' | head -20

echo
echo "===== E. MYSQL / MARIADB ====="
systemctl is-active mysql 2>/dev/null || systemctl is-active mariadb 2>/dev/null
mysql --connect-timeout=3 -e "
SHOW GLOBAL STATUS WHERE Variable_name IN (
  'Threads_running','Threads_connected','Max_used_connections','Slow_queries',
  'Created_tmp_tables','Created_tmp_disk_tables','Aborted_connects','Questions',
  'Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests','Innodb_row_lock_waits'
);
SHOW GLOBAL VARIABLES WHERE Variable_name IN (
  'innodb_buffer_pool_size','tmp_table_size','max_heap_table_size','max_connections',
  'table_open_cache','innodb_io_capacity','slow_query_log','long_query_time'
);
" 2>/dev/null
echo
echo "tmp table disk ratio:"
mysql --connect-timeout=3 -N -e "
SELECT CONCAT('tmp_disk_ratio=',
  IFNULL(ROUND(100*dds/NULLIF(tots,0),2),0),'% (',dds,'/',tots,')')
FROM (
  SELECT
    MAX(CASE WHEN Variable_name='Created_tmp_disk_tables' THEN Variable_value END)+0 dds,
    MAX(CASE WHEN Variable_name='Created_tmp_tables' THEN Variable_value END)+0 tots
  FROM performance_schema.global_status
  WHERE Variable_name IN ('Created_tmp_disk_tables','Created_tmp_tables')
) x;
" 2>/dev/null || true
echo
echo "largest tables across app DBs:"
mysql --connect-timeout=3 -e "
SELECT table_schema, table_name,
  ROUND((data_length+index_length)/1024/1024) AS mb,
  table_rows
FROM information_schema.tables
WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
ORDER BY (data_length+index_length) DESC LIMIT 20;
" 2>/dev/null
echo
echo "active non-sleep processlist:"
mysql --connect-timeout=3 -e "
SELECT ID,USER,DB,TIME,STATE,LEFT(INFO,120) q
FROM information_schema.processlist
WHERE COMMAND<>'Sleep' AND ID<>CONNECTION_ID()
ORDER BY TIME DESC LIMIT 15;
" 2>/dev/null
echo
echo "slow query log tail patterns:"
for f in /var/log/mysql/slow-query.log /var/log/mysql/mariadb-slow.log /var/lib/mysql/*-slow.log; do
  [ -f "$f" ] || continue
  echo "--- $f ---"
  tail -n 200 "$f" 2>/dev/null | grep -E '^# Query_time|SELECT|UPDATE|INSERT' | tail -n 40
done

echo
echo "===== F. REDIS QUICK RECHECK ====="
if command -v redis-cli >/dev/null 2>&1; then
  if type rc >/dev/null 2>&1 && rc ping 2>/dev/null | grep -q PONG; then
    rc INFO memory 2>/dev/null | grep -E 'used_memory_human|maxmemory_human|mem_fragmentation_ratio|evicted_keys'
    rc INFO stats 2>/dev/null | grep -E 'instantaneous_ops_per_sec|keyspace_hits|keyspace_misses|rejected_connections'
    rc SLOWLOG LEN 2>/dev/null
  elif redis-cli ping 2>/dev/null | grep -q PONG; then
    redis-cli INFO memory 2>/dev/null | grep -E 'used_memory_human|maxmemory_human|mem_fragmentation_ratio'
  else
    echo "Redis auth needed; see section 543"
  fi
fi
grep -iE 'objectcache|OOM command|WRONGPASS|NOAUTH' /var/log/syslog 2>/dev/null | tail -n 15

echo
echo "===== G. VARNISH QUICK RECHECK ====="
if pgrep -x varnishd >/dev/null 2>&1; then
  varnishstat -1 2>/dev/null | awk '
    $1=="MAIN.cache_hit"{h=$2}
    $1=="MAIN.cache_miss"{m=$2}
    $1=="MAIN.cache_hitpass"{p=$2}
    $1=="MAIN.n_lru_nuked"{n=$2}
    $1=="MAIN.backend_fail"{bf=$2}
    $1=="MAIN.client_req"{r=$2}
    END{
      lookups=h+m+p
      printf "hit=%d miss=%d hitpass=%d req=%d lru_nuked=%d backend_fail=%d hit%%_lookups=%.1f hit%%_req=%.1f\n",
        h,m,p,r,n,bf,lookups?h*100/lookups:0,r?h*100/r:0
    }'
  varnishadm backend.list 2>/dev/null | head -20
else
  echo "varnishd not running"
fi

echo
echo "===== H. BOT / ABUSE SIGNAL SWEEP ====="
echo "spoofed/high Chrome majors + known scrapers (nginx status last 5000/app):"
for f in /home/master/applications/*/logs/nginx-app.status.log; do
  [ -f "$f" ] || continue
  app=$(echo "$f" | awk -F/ '{print $(NF-2)}')
  echo "--- $app ---"
  tail -n 5000 "$f" 2>/dev/null | grep -oE 'Chrome/[0-9]+' | sort | uniq -c | sort -nr | head -8
  tail -n 5000 "$f" 2>/dev/null | grep -oiE 'ShapBot|ClearstromBot|RiverBot|ComponentsFinder|Bytespider|GPTBot|petalsearch|HeadlessChrome' | sort | uniq -c | sort -nr | head -10
done
echo
echo "top IPs last 5000 backend hits + AbuseIPDB hint list (manual follow-up):"
for d in /home/master/applications/*/; do
  app=$(basename "$d")
  blog=$(ls "$d"logs/backend_*.access.log 2>/dev/null | head -1)
  [ -f "$blog" ] || continue
  echo "--- $app ---"
  tail -n 5000 "$blog" 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -nr | head -15
done

echo
echo "===== I. STACK HEALTH FLAGS ====="
# PHP pool saturation
MCALL=$(grep -h 'server reached pm.max_children' /var/log/php*-fpm.log /var/log/php*/*fpm*.log 2>/dev/null | wc -l)
[ "${MCALL:-0}" -gt 0 ] && echo "FLAG: php-fpm max_children warnings total=$MCALL"
# Swap
SWAPUSED=$(free -m | awk '/Swap/{print $3}')
[ "${SWAPUSED:-0}" -gt 256 ] && echo "FLAG: swap in use ${SWAPUSED} MB"
# Disk tmp tables
mysql --connect-timeout=3 -N -e "
SELECT IF(dds/NULLIF(tots,0)>0.25,
  CONCAT('FLAG: tmp tables on disk ratio ',ROUND(100*dds/tots,1),'%'),
  NULL)
FROM (
  SELECT
    MAX(CASE WHEN Variable_name='Created_tmp_disk_tables' THEN Variable_value END)+0 dds,
    MAX(CASE WHEN Variable_name='Created_tmp_tables' THEN Variable_value END)+0 tots
  FROM performance_schema.global_status
  WHERE Variable_name IN ('Created_tmp_disk_tables','Created_tmp_tables')
) x;
" 2>/dev/null
# Woo ajax dominance
for d in /home/master/applications/*/; do
  blog=$(ls "$d"logs/backend_*.access.log 2>/dev/null | head -1)
  [ -f "$blog" ] || continue
  app=$(basename "$d")
  tot=$(tail -n 3000 "$blog" 2>/dev/null | wc -l)
  ajax=$(tail -n 3000 "$blog" 2>/dev/null | grep -cE 'admin-ajax|wc-ajax')
  awk -v a="$ajax" -v t="$tot" -v app="$app" 'BEGIN{if(t>0 && a/t>0.25) printf "FLAG: %s ajax/wc-ajax is %.0f%% of last %d backend hits\n",app,a*100/t,t}'
done
echo "Stack deep checks complete."
