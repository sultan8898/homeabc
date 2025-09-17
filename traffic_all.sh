#!/bin/bash

for A in $(ls -l /home/master/applications/ | grep "^d" | awk '{print $NF}'); do
  echo -e "\n\n🔍 DB: $A"

  # Show server name from nginx config
  awk 'NR==1 {print "Server:", substr($NF, 1, length($NF)-1)}' /home/master/applications/$A/conf/server.nginx

  # Extract top IPs from logs
  cat /home/master/applications/$A/logs/nginx-app.status.log | tr -d '\000' | awk '{print $1}' | \
  grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|::1|fc[0-9a-f]{2}:|fd[0-9a-f]{2}:|fe[89ab][0-9a-f]:)' | \
  sort | uniq -c | sort -nr | head -n 20 > /tmp/${A}_ip_hits.txt

  echo -e "\n🌐 Top IPs and Country Mapping:"
  cut -c9- /tmp/${A}_ip_hits.txt | while read -r ip; do
    if [[ "$ip" == *:* ]]; then out=$(geoiplookup6 "$ip"); else out=$(geoiplookup "$ip"); fi
    cc=$(echo "$out" | sed -n 's/.*Country[^:]*: \([A-Z][A-Z]\),.*/\1/p')
    [[ -z "$cc" ]] && cc="Unknown"
    echo "$ip → $cc"
  done

  echo -e "\n📊 Aggregated Hits by Country:"
  join -1 2 -2 1 <(sort -k2,2 /tmp/${A}_ip_hits.txt) <(
    cut -c9- /tmp/${A}_ip_hits.txt | while read -r ip; do
      if [[ "$ip" == *:* ]]; then out=$(geoiplookup6 "$ip"); else out=$(geoiplookup "$ip"); fi
      cc=$(echo "$out" | sed -n 's/.*Country[^:]*: \([A-Z][A-Z]\),.*/\1/p')
      [[ -z "$cc" ]] && cc="Unknown"
      echo -e "$ip\t$cc"
    done | sort -k1,1
  ) | awk '{counts[$3]+=$1} END{for (c in counts) printf "%d %s\n", counts[c], c}' | sort -nr

done
