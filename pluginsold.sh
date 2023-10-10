#!/bin/bash

# Default paths
plugins_path="./wp-content/plugins"
themes_path="./wp-content/themes"
log_path="../logs/php-app.slow.log.1"

# Get a list of all plugins and themes
plugins=$(find "$plugins_path" -maxdepth 1 -type d | sed 's|.*/||')
themes=$(find "$themes_path" -maxdepth 1 -type d | sed 's|.*/||')

# Initialize associative arrays to store the counts of each plugin and theme
declare -A plugin_counts
declare -A theme_counts

# Loop through each plugin and search for entries in the slow logs
for plugin in $plugins; do
  # Search the slow logs for entries related to the current plugin and extract the plugin name
  log_entries=$(grep -o "plugins/$plugin/." "$log_path" | sed 's/plugins\/.\///')

  # If there are log entries, print them and update the count for the plugin
  if [ -n "$log_entries" ]; then
    echo "Entries for plugin $plugin:"
    echo "$log_entries"
    echo ""
    for entry in $log_entries; do
      (( plugin_counts[$plugin]++ ))
    done
  fi
done

# Loop through each theme and search for entries in the slow logs
for theme in $themes; do
  # Search the slow logs for entries related to the current theme and extract the theme name
  log_entries=$(grep -o "themes/$theme/." "$log_path" | sed 's/themes\/.\///')

  # If there are log entries, print them and update the count for the theme
  if [ -n "$log_entries" ]; then
    echo "Entries for theme $theme:"
    echo "$log_entries"
    echo ""
    for entry in $log_entries; do
      (( theme_counts[$theme]++ ))
    done
  fi
done

# Print the top N plugins and themes with the highest counts
echo "Top plugins by count:"
for plugin in "${!plugin_counts[@]}"; do
  echo "${plugin_counts[$plugin]} $plugin"
done | sort -rn | head -n 10

echo "Top themes by count:"
for theme in "${!theme_counts[@]}"; do
  echo "${theme_counts[$theme]} $theme"
done | sort -rn | head -n 10
