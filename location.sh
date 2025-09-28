#!/bin/bash
# Count hits per public IP from the log file

LOG_FILE="nginx-app.status.log"
IP_COUNTS="/tmp/ip_counts.txt"

if [[ ! -f "$LOG_FILE" ]]; then
  echo "Error: Log file '$LOG_FILE' not found."
  exit 1
fi

awk '
function is_private4(ip) {
  return ip ~ /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/
}
function is_private6(ip) {
  ip = tolower(ip)
  return ip == "::1" || ip ~ /^(fc|fd)[0-9a-f]{2}:/ || ip ~ /^fe[89ab][0-9a-f]:/
}
{
  ip = $1
  if ((ip ~ /:/ && !is_private6(ip)) || (ip !~ /:/ && !is_private4(ip))) {
    count[ip]++
  }
}
END {
  for (ip in count) {
    printf "%d %s\n", count[ip], ip
  }
}
' "$LOG_FILE" > "$IP_COUNTS"
