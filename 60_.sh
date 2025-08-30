#!/bin/bash

# Path to your Apache log file
LOG_FILE="nginx-app.status.log"

# Interval for monitoring (in seconds)
MONITOR_INTERVAL=60

echo "Monitoring traffic from $LOG_FILE ..."
echo "Press [Ctrl+C] to stop."

# Loop to continuously monitor traffic
while true; do
    echo -e "\n--- Traffic Summary (last $MONITOR_INTERVAL seconds) ---"

    # Extract IPs from the log file, count occurrences, and sort by hits
    tail -n 10000 "$LOG_FILE" | awk '{print $1}' | sort | uniq -c | sort -nr | head -n 10

    # Wait for the specified interval before the next check
    sleep $MONITOR_INTERVAL
done

#To fetch IPs per 60 seconds < top 10 
