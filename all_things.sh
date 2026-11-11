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
