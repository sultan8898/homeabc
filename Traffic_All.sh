#!/bin/bash

echo -e "\n🕒 Report generated at: $(date)\n"

# Loop through each application directory
for A in $(find /home/master/applications/ -mindepth 1 -maxdepth 1 -type d -printf "%f\n"); do
  echo -e "\n\n🔍 DB: $A"

  # Show server name from nginx config
  config_file="/home/master/applications/$A/conf/server.nginx"
  if [[ -f "$config_file" ]]; then
    awk 'NR==1 {print "Server:", substr($NF, 1, length($NF)-1)}' "$config_file"
  else
    echo "⚠️ Config file not found for $A"
    continue
  fi

  # Check if log file exists
  log_file="/home/master/applications/$A/logs/nginx-app.status.log"
  if [[ ! -f "$log_file" ]]; then
    echo "⚠️ Log file not found for $A"
    continue
  fi

  # Extract top public IPs from logs
  awk '{print $1}' "$log_file" | \
  grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|::1|fc[0-9a-f]{2}:|fd[0-9a-f]{2}:|fe[89ab][0-9a-f]:)' | \
  sort | uniq -c | sort -nr | head -n 20 > "/tmp/${A}_ip_hits.txt"

  echo -e "\n🌐 Top IPs and Country Mapping:"
  awk '{print $2}' "/tmp/${A}_ip_hits.txt" | while read -r ip; do
    if [[ "$ip" == *:* ]]; then
      out=$(geoiplookup6 "$ip")
    else
      out=$(geoiplookup "$ip")
    fi
    cc=$(echo "$out" | sed -n 's/.*Country[^:]*: \([A-Z][A-Z]\),.*/\1/p')
    [[ -z "$cc" ]] && cc="Unknown"
    echo "$ip → $cc"
  done

  echo -e "\n📊 Aggregated Hits by Country:"
  join -1 2 -2 1 <(sort -k2,2 "/tmp/${A}_ip_hits.txt") <(
    awk '{print $2}' "/tmp/${A}_ip_hits.txt" | while read -r ip; do
      if [[ "$ip" == *:* ]]; then
        out=$(geoiplookup6 "$ip")
      else
        out=$(geoiplookup "$ip")
      fi
      cc=$(echo "$out" | sed -n 's/.*Country[^:]*: \([A-Z][A-Z]\),.*/\1/p')
      [[ -z "$cc" ]] && cc="Unknown"
      echo -e "$ip\t$cc"
    done | sort -k1,1
  ) | awk '{counts[$3]+=$1} END{for (c in counts) printf "%d %s\n", counts[c], c}' | sort -nr

done
