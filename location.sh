#!/bin/bash
# Count hits per public IP from nginx-app.status.log and map to countries.
#
# Usage: ./location.sh [LOG_FILE]
# Default LOG_FILE: ./nginx-app.status.log (run from app logs/ directory)

set -euo pipefail

LOG_FILE="${1:-nginx-app.status.log}"
IP_COUNTS="/tmp/ip_counts_$$.txt"

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
' "$LOG_FILE" | sort -nr > "$IP_COUNTS"

echo "Top public IPs:"
head -n 20 "$IP_COUNTS" | while read -r hits ip; do
  if [[ "$ip" == *:* ]]; then out=$(geoiplookup6 "$ip" 2>/dev/null); else out=$(geoiplookup "$ip" 2>/dev/null); fi
  cc=$(echo "$out" | sed -n 's/.*Country[^:]*: \([A-Z][A-Z]\),.*/\1/p')
  [[ -z "$cc" ]] && cc="Unknown"
  printf "%6d  %-15s  %s\n" "$hits" "$ip" "$cc"
done

echo ""
echo "Aggregated hits by country (top 20):"
while read -r hits ip; do
  if [[ "$ip" == *:* ]]; then out=$(geoiplookup6 "$ip" 2>/dev/null); else out=$(geoiplookup "$ip" 2>/dev/null); fi
  cc=$(echo "$out" | sed -n 's/.*Country[^:]*: \([A-Z][A-Z]\),.*/\1/p')
  [[ -z "$cc" ]] && cc="Unknown"
  echo -e "$hits\t$cc"
done < "$IP_COUNTS" | awk '{counts[$2]+=$1} END{for (c in counts) printf "%d %s\n", counts[c], c}' | sort -nr | head -n 20

rm -f "$IP_COUNTS"
