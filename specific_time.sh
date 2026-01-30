#!/bin/bash

# Ask for date and timeframe
read -p "Enter date (DD/MM/YYYY): " run_date
read -p "Enter start time (HH:MM): " start_time
read -p "Enter end time (HH:MM): " end_time

# Ask whether to run for one app or all
read -p "Run for one app or all apps? (one/all): " choice

apps=()
if [ "$choice" == "one" ]; then
    read -p "Enter the app name: " app
    apps=("$app")
else
    # Collect all app names dynamically
    apps=($(ls -l /home/master/applications/ | grep "^d" | awk '{print $NF}'))
fi

# Ask whether to check php or mysql traffic
read -p "Check traffic for php or mysql? (php/mysql): " traffic_type

# Loop through apps
for app in "${apps[@]}"; do
    echo -e "\n\nDB: $app"

    # Print nginx server name
    awk 'NR==1 {print substr($NF, 1, length($NF)-1)}' /home/master/applications/$app/conf/server.nginx

    # Show top RAM consumers from logs
    cat /home/master/applications/$app/logs/php-app.access.log | tr -d '\000' \
        | sort -nbrk 13,13 | head \
        | awk '{print $1,$3,$5,$16,"   ====>   ",$13/1024/1024, "MB of RAM consumed"}'

    # Run traffic command
    /usr/local/sbin/apm traffic -s "$app" -f "$run_date:$start_time" -u "$run_date:$end_time" "$traffic_type"
done
