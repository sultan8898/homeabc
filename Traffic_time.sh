#!/bin/bash

set -e

# =========================
# INPUT SECTION (TTY SAFE)
# =========================
read -p "Enter date (DD/MM/YYYY): " run_date </dev/tty
read -p "Enter start time (HH:MM): " start_time </dev/tty
read -p "Enter end time (HH:MM): " end_time </dev/tty

read -p "Run for one app or all apps? (one/all): " choice </dev/tty

apps=()
if [[ "$choice" == "one" ]]; then
    read -p "Enter the app name: " app </dev/tty
    apps=("$app")
else
    mapfile -t apps < <(find /home/master/applications/ -maxdepth 1 -type d -printf "%f\n")
fi

read -p "Check traffic for php or mysql? (php/mysql): " traffic_type </dev/tty

# =========================
# PROCESSING SECTION
# =========================
for app in "${apps[@]}"; do
    echo -e "\n=============================="
    echo "DB: $app"
    echo "=============================="

    # Print server name
    server_conf="/home/master/applications/$app/conf/server.nginx"
    if [[ -f "$server_conf" ]]; then
        awk 'NR==1 {print substr($NF, 1, length($NF)-1)}' "$server_conf"
    else
        echo "Server config not found"
    fi

    # Top PHP RAM consumers
    log_file="/home/master/applications/$app/logs/php-app.access.log"
    if [[ -f "$log_file" ]]; then
        tr -d '\000' < "$log_file" \
        | sort -nbrk 13,13 \
        | head \
        | awk '{print $1,$3,$5,$16,"  ====> ",$13/1024/1024,"MB RAM"}'
    else
        echo "PHP access log not found"
    fi

    # Run APM traffic
    /usr/local/sbin/apm traffic \
        -s "$app" \
        -f "$run_date:$start_time" \
        -u "$run_date:$end_time" \
        "$traffic_type"
done
