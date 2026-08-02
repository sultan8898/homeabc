#!/bin/bash
# ============================================================================ #
#  CLOUDWAYS SERVER AUDIT v2 - CPU ROOT-CAUSE EDITION                          #
#  Adds detections built from recurring CPU cases:                             #
#   - Cache-bypass query strings (gclid/utm/noamp random cache-busters)        #
#   - Faceted-nav / filter permutation floods (Woo, Events Calendar, Magento)  #
#   - Distributed residential proxy swarms (/24 rotation, UA-vs-IP spread)     #
#   - Uncacheable PHP endpoint pressure (admin-ajax, wc-ajax, wp-json, cron)   #
#   - Saturation event windows (499/5xx clustering per minute)                 #
#   - Cache effectiveness proxy (frontend vs backend log time-span)            #
#   - wp-cron stampede detection (per app + synchronized across apps)          #
#   - OOM kills / FPM+MySQL restarts, load + top CPU consumers                 #
# ============================================================================ #

# Number of recent log lines to analyze per log. 1000 is fine for quiet
# servers; raise to 5000-10000 during an active incident so per-minute
# breakdowns cover a real window.
N=${1:-1000}

echo "=========================================================="
echo " SERVER SNAPSHOT (right now)"
echo "=========================================================="
echo -e "\n---> Load Average / Uptime:"
uptime

echo -e "\n---> Top 10 CPU Consumers (live):"
ps -eo pcpu,pmem,user,pid,comm --sort=-pcpu 2>/dev/null | head -n 11

echo -e "\n---> OOM Kills in Kernel Log (last 5):"
dmesg -T 2>/dev/null | grep -iE "out of memory|oom-kill|killed process" | tail -n 5
grep -iE "oom-kill|out of memory" /var/log/syslog 2>/dev/null | tail -n 3

echo -e "\n---> Recent php-fpm / mysql restarts (syslog, last 5):"
grep -iE "php[0-9.]*-fpm.*(started|stopp|exit|kill)|mysqld.*(shutdown|start|crash)" /var/log/syslog 2>/dev/null | tail -n 5

for A in $(ls -l /home/master/applications/ | grep "^d" | awk '{print $NF}'); do
    echo -e "\n\n=========================================================="
    echo "App Directory: $A"

    # Grab the primary domain name for easy identification
    awk 'NR==1{print "Domain: " substr($NF,1,length($NF)-1)}' /home/master/applications/$A/conf/server.nginx 2>/dev/null

    # Dynamically extract the full Cloudways app identifier
    APP_PREFIX=$(grep -oP '[a-zA-Z0-9_]+-[0-9]+-[0-9]+(?=\.cloudwaysapps\.com)' /home/master/applications/$A/conf/server.nginx 2>/dev/null | head -n 1)

    if [ -n "$APP_PREFIX" ]; then
        LOG_DIR="/home/master/applications/$A/logs"
        ACCESS_LOG="$LOG_DIR/backend_${APP_PREFIX}.cloudwaysapps.com.access.log"
        SLOW_LOG="$LOG_DIR/php-app.slow.log"
        PHP_ACCESS_LOG="$LOG_DIR/php-app.access.log"
        NGINX_STATUS_LOG="$LOG_DIR/nginx-app.status.log"

        echo "=========================================================="

        # ---------------- NGINX FRONTEND LOGS (All Traffic) ---------------- #
        if [ -f "$NGINX_STATUS_LOG" ]; then
            echo -e "\n---> HTTP Status Code Breakdown (Recent $N requests):"
            tail -n $N "$NGINX_STATUS_LOG" 2>/dev/null | awk '{print $9}' | grep -E '^[1-5][0-9]{2}$' | sort | uniq -c | sort -nr | head -n 10

            echo -e "\n---> Peak Traffic Minutes (Highest hits per minute):"
            tail -n $N "$NGINX_STATUS_LOG" 2>/dev/null | awk '{print $4}' | cut -c2-18 | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> SATURATION WINDOWS: 499/5xx clustered per minute (FPM stall/backend-down events):"
            tail -n $N "$NGINX_STATUS_LOG" 2>/dev/null | awk '$9 == 499 || $9 ~ /^50/ {print substr($4,2,17), $9}' | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> Top 5 '404 Not Found' Errors (Missing Files/Pages):"
            tail -n $N "$NGINX_STATUS_LOG" 2>/dev/null | awk '$9 == 404 {print $7}' | cut -d? -f1 | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> Top 5 Bandwidth Hogs (Total Data Transferred):"
            tail -n $N "$NGINX_STATUS_LOG" 2>/dev/null | awk '{bytes[$7]+=$10} END {for (url in bytes) { if(bytes[url]>1024) printf "%9.2f MB ===> %s\n", bytes[url]/1024/1024, url }}' | sort -nr | head -n 5

            echo -e "\n---> Top 5 Pages Triggering AJAX (admin-ajax.php Sources):"
            tail -n $N "$NGINX_STATUS_LOG" 2>/dev/null | grep "admin-ajax.php" | awk -F'"' '{print $4}' | grep -v "^-$" | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> Top 5 Referrers (Where traffic is arriving from):"
            tail -n $N "$NGINX_STATUS_LOG" 2>/dev/null | awk -F'"' '{print $4}' | grep -v "admin-ajax.php" | grep -v "^-$" | grep -v "$(awk 'NR==1{print substr($NF,1,length($NF)-1)}' /home/master/applications/$A/conf/server.nginx 2>/dev/null)" | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> Top 5 'Abandoned' Requests (499 Timeouts):"
            tail -n $N "$NGINX_STATUS_LOG" 2>/dev/null | awk '$9 == 499 {print $7}' | cut -d? -f1 | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> Top 5 Server Errors (5xx crashes):"
            tail -n $N "$NGINX_STATUS_LOG" 2>/dev/null | awk '$9 ~ /^50/ {print $9, $7}' | sort | uniq -c | sort -nr | head -n 5
        fi

        # ---------------- PHP/BACKEND LOGS (Dynamic Traffic) ---------------- #
        if [ -f "$ACCESS_LOG" ]; then
            UNIQUE_IPS=$(tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '{print $1}' | sort | uniq | wc -l)
            echo -e "\n---> Traffic Distribution: $UNIQUE_IPS Unique IPs (out of last $N PHP hits)"
            echo "     (If this is very high, e.g. 800+ of 1000, suspect a rotating residential proxy swarm: per-IP rate limits will NOT work)"

            # -------- CACHE EFFECTIVENESS PROXY -------- #
            # If the backend log covers roughly the same time window as the
            # frontend log, nearly ALL traffic is reaching PHP (cache bypass).
            FE_SPAN=$(tail -n $N "$NGINX_STATUS_LOG" 2>/dev/null | awk 'NR==1{f=substr($4,2,20)} END{print f "  ->  " substr($4,2,20)}')
            BE_SPAN=$(tail -n $N "$ACCESS_LOG" 2>/dev/null | awk 'NR==1{f=substr($4,2,20)} END{print f "  ->  " substr($4,2,20)}')
            echo -e "\n---> Cache Effectiveness Check (time window of last $N lines):"
            echo "     Frontend (all traffic): $FE_SPAN"
            echo "     Backend  (PHP only)   : $BE_SPAN"
            echo "     (Backend window ~= Frontend window means cache is being bypassed at scale)"

            # -------- CACHE-BYPASS QUERY STRING ANALYSIS -------- #
            QS_TOTAL=$(tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '{print $7}' | grep -c '?')
            TRACKER=$(tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '{print $7}' | grep -cE '[?&](gclid|fbclid|gbraid|wbraid|gad_|utm_|_gl|srsltid|msclkid|noamp|nocache|ver|v)=')
            echo -e "\n---> Cache-Bypass Pressure: $QS_TOTAL of $N PHP hits carry query strings ($TRACKER match known tracking/cache-buster params)"

            echo -e "\n---> Top 10 Query Parameter Names (facet/tracker fingerprint):"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '{print $7}' | grep -oP '(?<=[?&])[A-Za-z0-9_%\[\]-]+(?==)' | sort | uniq -c | sort -nr | head -n 10

            echo -e "\n---> CACHE-BUSTER TARGETS: paths with many unique query-string variants (facet permutation / random-param floods):"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '{print $7}' | awk -F'?' 'NF>1 {hits[$1]++; if(!seen[$0]++) var[$1]++} END {for (p in var) if (var[p] >= 10) printf "%6d variants / %6d hits ===> %s\n", var[p], hits[p], p}' | sort -nr | head -n 5

            echo -e "\n---> Faceted-Nav / Archive Crawl Hits (Woo filters, Events Calendar, tag/size/color archives):"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '{print $7}' | grep -iE '([?&](filter_|category=|brands=|orderby=|min_price|max_price|tribe-bar-date|eventDisplay|product_cat|pa_))|(/product-tag/|/product-category/.*[?&]|/size/|/color/|ical=|outlook-ical)' | cut -d? -f1 | sort | uniq -c | sort -nr | head -n 5

            # -------- UNCACHEABLE PHP ENDPOINT PRESSURE -------- #
            echo -e "\n---> Uncacheable PHP Endpoint Pressure (all land straight on FPM):"
            for EP in "admin-ajax.php" "wc-ajax=" "/wp-json/" "wp-cron.php" "xmlrpc.php" "wp-login.php" "add-to-cart" "/checkout" "/my-account" "system_status"; do
                C=$(tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '{print $7}' | grep -cF "$EP")
                [ "$C" -gt 0 ] && printf "     %6d ===> %s\n" "$C" "$EP"
            done

            echo -e "\n---> Top 5 Hit URLs (PHP):"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '{print $7}' | cut -d? -f1 | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> Top 5 Most Aggressive IPs:"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> SWARM CHECK: Top 5 /24 Subnets (hits + rotating IP count within subnet):"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '{split($1,o,"."); sn=o[1]"."o[2]"."o[3]".0/24"; c[sn]++; k=sn SUBSEP $1; if(!s[k]++) u[sn]++} END {for (x in c) printf "%6d hits from %4d IPs ===> %s\n", c[x], u[x], x}' | sort -nr | head -n 5

            echo -e "\n---> Top 5 User-Agents / Bots:"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | awk -F'"' '{print $6}' | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> UA SWARM SIGNATURE: high-volume UAs and how many distinct IPs use them:"
            echo "     (1 UA across hundreds of IPs = proxy swarm; block by UA/pattern, not IP)"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | awk -F'"' '{split($1,a," "); ip=a[1]; ua=$6; c[ua]++; k=ua SUBSEP ip; if(!s[k]++) ips[ua]++} END {for (u in c) if (c[u] >= 20) printf "%6d hits from %4d IPs ===> %.75s\n", c[u], ips[u], u}' | sort -nr | head -n 8

            echo -e "\n---> Known Crawler / AI-Bot Volume (SEO + AI + intent-data scrapers):"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | awk -F'"' '{print $6}' | grep -oiE 'googlebot|bingbot|applebot|yandex|ahrefs|semrush|mj12bot|dotbot|petalbot|bytespider|amazonbot|gptbot|claudebot|ccbot|perplexity|meta-external|facebookexternalhit|bombora|pinterest|uptimerobot|geedo' | tr '[:upper:]' '[:lower:]' | sort | uniq -c | sort -nr | head -n 10

            echo -e "\n---> wp-cron Stampede Check (wp-cron.php hits per minute, this app):"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | grep "wp-cron.php" | awk '{print substr($4,2,17)}' | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> Top 5 Plugin Endpoints (REST API & AJAX):"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '{print $7}' | grep -E "/wp-json/|admin-ajax.php" | cut -d? -f1 | cut -d/ -f1-4 | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> POST Flood Check (Top POST targets - logins, carts, APIs):"
            tail -n $N "$ACCESS_LOG" 2>/dev/null | awk '$6 == "\"POST" {print $7}' | cut -d? -f1 | sort | uniq -c | sort -nr | head -n 5
        else
            echo "Backend access log not found for this app."
        fi

        # ---------------- PHP WORKER LOGS (Performance) ---------------- #
        if [ -f "$PHP_ACCESS_LOG" ]; then
            echo -e "\n---> Top 5 Memory-Heavy PHP Requests:"
            tail -n $N "$PHP_ACCESS_LOG" 2>/dev/null | tr -d '\000' | sort -k13 -nr | head -n 5 | awk '{printf "%-15s %-45s ===> %.2f MB\n", $1, $6, $13/1024/1024}' | sed 's/"//g'

            echo -e "\n---> Top 5 Slowest PHP Requests (CPU Time):"
            tail -n $N "$PHP_ACCESS_LOG" 2>/dev/null | tr -d '\000' | sort -k12 -nr | head -n 5 | awk '{printf "%-15s %-45s ===> %s Secs\n", $1, $6, $12}' | sed 's/"//g'
        fi

        if [ -s "$SLOW_LOG" ]; then
            SLOW_COUNT=$(tail -n $N "$SLOW_LOG" 2>/dev/null | grep -c "^\[.*pool")
            echo -e "\n---> Slow Log Entry Count (recent window): $SLOW_COUNT stack traces"

            echo -e "\n---> Top 5 Slow Plugins (From PHP Slow Log):"
            tail -n $N "$SLOW_LOG" 2>/dev/null | grep -oP 'wp-content/plugins/\K[^/]+' | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> Top 5 Slow Entry Scripts (script_filename - what request type is stalling):"
            tail -n $N "$SLOW_LOG" 2>/dev/null | grep -oP 'script_filename = \K.*' | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> Top 5 Functions Where Workers Are Stuck (top-of-stack frames):"
            tail -n $N "$SLOW_LOG" 2>/dev/null | grep -oP '^\[0x[0-9a-f]+\] \K[A-Za-z0-9_:>-]+(?=\()' | sort | uniq -c | sort -nr | head -n 5
        else
            echo -e "\n---> Top 5 Slow Plugins:\nNo recent slow logs recorded (FPM request_slowlog not triggering)."
        fi

        # ---------------- ERROR/SECURITY LOGS ---------------- #
        if ls "$LOG_DIR"/*error.log 1> /dev/null 2>&1; then
            echo -e "\n---> Top 5 Blocked Hacking/Probe Attempts:"
            tail -n $N "$LOG_DIR"/*error.log 2>/dev/null | grep "access forbidden by rule" | awk -F'request: "' '{print $2}' | cut -d' ' -f2 | sort | uniq -c | sort -nr | head -n 5

            echo -e "\n---> Top 5 Upstream Errors (FPM timeouts, connection refused, limits):"
            tail -n $N "$LOG_DIR"/*error.log 2>/dev/null | grep -oiE "upstream timed out|connect\(\) failed|no live upstreams|worker_connections|limiting requests" | sort | uniq -c | sort -nr | head -n 5
        fi

    else
        echo "=========================================================="
        echo "No valid App Prefix found. Skipping..."
    fi
done

# ============================================================================== #
#                       GLOBAL SERVER-WIDE SUMMARY                               #
# ============================================================================== #

echo -e "\n\n=========================================================="
echo "          GLOBAL AUDIT SUMMARY (ACROSS ALL APPS)          "
echo "=========================================================="

echo -e "\n---> Top 10 Most Aggressive IPs Across ALL Apps:"
tail -q -n $N /home/master/applications/*/logs/backend_*.cloudwaysapps.com.access.log 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -nr | head -n 10

echo -e "\n---> GLOBAL SWARM CHECK: Top 10 /24 Subnets Across ALL Apps (hits + IP rotation):"
tail -q -n $N /home/master/applications/*/logs/backend_*.cloudwaysapps.com.access.log 2>/dev/null | awk '{split($1,o,"."); sn=o[1]"."o[2]"."o[3]".0/24"; c[sn]++; k=sn SUBSEP $1; if(!s[k]++) u[sn]++} END {for (x in c) printf "%6d hits from %4d IPs ===> %s\n", c[x], u[x], x}' | sort -nr | head -n 10

echo -e "\n---> Top 10 User-Agents / Bots Across ALL Apps:"
tail -q -n $N /home/master/applications/*/logs/backend_*.cloudwaysapps.com.access.log 2>/dev/null | awk -F'"' '{print $6}' | sort | uniq -c | sort -nr | head -n 10

echo -e "\n---> Global Cache-Bypass Share (PHP hits carrying query strings):"
tail -q -n $N /home/master/applications/*/logs/backend_*.cloudwaysapps.com.access.log 2>/dev/null | awk '{print $7}' | awk -F'?' 'NF>1{q++} {t++} END {if(t>0) printf "     %d of %d backend hits carry query strings (%.0f%%)\n", q, t, q/t*100}'

echo -e "\n---> GLOBAL wp-cron Stampede (wp-cron.php hits per minute, ALL apps combined):"
echo "     (Multiple apps firing on the same minute boundary = synchronized cron spike; stagger them)"
tail -q -n $N /home/master/applications/*/logs/backend_*.cloudwaysapps.com.access.log 2>/dev/null | grep "wp-cron.php" | awk '{print substr($4,2,17)}' | sort | uniq -c | sort -nr | head -n 5

echo -e "\n---> Top 10 Memory-Heavy PHP Requests Across ALL Apps:"
tail -q -n $N /home/master/applications/*/logs/php-app.access.log 2>/dev/null | tr -d '\000' | sort -k13 -nr | head -n 10 | awk '{printf "%-15s %-45s ===> %.2f MB\n", $1, $6, $13/1024/1024}' | sed 's/"//g'

echo -e "\n---> Top 10 Slowest PHP Requests Across ALL Apps (CPU Time):"
tail -q -n $N /home/master/applications/*/logs/php-app.access.log 2>/dev/null | tr -d '\000' | sort -k12 -nr | head -n 10 | awk '{printf "%-15s %-45s ===> %s Secs\n", $1, $6, $12}' | sed 's/"//g'

# ---------------- MySQL SLOW QUERY LOG ---------------- #
echo -e "\n---> Top 10 Slowest MySQL Queries (Truncated):"
if [ -f "/var/log/mysql/slow-query.log" ]; then
    tail -n 10000 "/var/log/mysql/slow-query.log" 2>/dev/null | awk '
    /^# Query_time:/ { q_time=$3 }
    /^[a-zA-Z]/ && !/^SET timestamp/ && !/^use / {
        if (q_time != "") {
            query=substr($0, 1, 100)
            printf "%05.2f Secs ===> %s...\n", q_time, query
            q_time=""
        }
    }' | sort -nr | head -n 10
else
    echo "MySQL slow query log not found at /var/log/mysql/slow-query.log (or is disabled)."
fi

echo -e "\n---> MySQL Live Snapshot (running threads, guarded):"
mysql -e "SHOW GLOBAL STATUS LIKE 'Threads_running'; SHOW GLOBAL STATUS LIKE 'Threads_connected';" 2>/dev/null
mysql -e "SELECT ID, USER, TIME, STATE, LEFT(INFO,90) AS QUERY_HEAD FROM information_schema.PROCESSLIST WHERE COMMAND != 'Sleep' ORDER BY TIME DESC LIMIT 10;" 2>/dev/null

echo -e "\n=========================================================="
echo "                     END OF AUDIT REPORT                  "
echo "=========================================================="
