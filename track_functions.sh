#!/bin/bash

# Path to your PHP-FPM slow log file
LOG_FILE="php-app.slow.log"

# Interval for monitoring (in seconds)
MONITOR_INTERVAL=30

# Function to count occurrences of specific patterns
echo "Monitoring PHP-FPM slow log from $LOG_FILE ..."
echo "Looking for specific slow functions in $MONITOR_INTERVAL-second intervals"
echo "Press [Ctrl+C] to stop."

# Loop to continuously monitor slow functions
while true; do
    echo -e "\n--- Slow Function Count (last $MONITOR_INTERVAL seconds) ---"

    # Count specific slow functions
    # Adjust the grep patterns based on what you want to track

    # Count __callPlugins occurrences
    CALL_PLUGINS_COUNT=$(tail -n 100 "$LOG_FILE" | grep -c "__callPlugins")

    # Count schemaValidate occurrences (from your first example)
    SCHEMA_VALIDATE_COUNT=$(tail -n 100 "$LOG_FILE" | grep -c "schemaValidate")

    # Count dispatch occurrences (from your second example)
    DISPATCH_COUNT=$(tail -n 100 "$LOG_FILE" | grep -c "dispatch()")

    # Count xpath occurrences (from your third example)
    XPATH_COUNT=$(tail -n 100 "$LOG_FILE" | grep -c "xpath()")

    # Display results
    echo "__callPlugins(): $CALL_PLUGINS_COUNT occurrences"
    echo "schemaValidate(): $SCHEMA_VALIDATE_COUNT occurrences"
    echo "dispatch(): $DISPATCH_COUNT occurrences"
    echo "xpath(): $XPATH_COUNT occurrences"

    # Total slow calls
    TOTAL=$((CALL_PLUGINS_COUNT + SCHEMA_VALIDATE_COUNT + DISPATCH_COUNT + XPATH_COUNT))
    echo "Total tracked slow calls: $TOTAL"

    # Wait for the specified interval before the next check
    sleep $MONITOR_INTERVAL
done
