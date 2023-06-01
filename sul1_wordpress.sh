#!/bin/bash
##This script goes through all of the access logs and writes down IPs that have accessed the site in the last month. It can be adjusted for any specifc day as well, if * .gz is replaced
##specific day is chosen as well. 
## The bot script is not complete inside it, if anyone wants to work on it, feel free to do so.
##Written by Sultan
# Get the WordPress server name from nginx config
server_name=$(awk '/^ *server_name/ && /wordpress/ {print $2; exit}' ../conf/server.nginx)

# Extract the code from the server name
code=$(echo "$server_name" | sed 's/wordpress-\([^-]*\)-\([^-]*\)\..*/\1-\2/')

# Create traffic.txt file
touch ../public_html/traffic.txt

# Extract IP addresses from logs and count occurrences
cat "../logs/apache_wordpress-$code.com.access.log" "../logs/apache_wordpress-$code.com.access.log.1" \
  | awk '{print $1}' \
  | sort \
  | uniq -c \
  | sort -rn \
  > ../public_html/traffic.txt

# Extract bot names from logs and count occurrences
cat "../logs/apache_wordpress-$code.com.access.log" "../logs/apache_wordpress-$code.com.access.log.1" \
  | awk 'tolower($0) ~ /bot/ {for (i=1;i<=NF;i++) if ($i ~ /bot$/) {print $(i-1); break}}' \
  | sort \
  | uniq -c \
  | sort -rn \
  >> ../public_html/traffic.txt

# Extract IP addresses from gzipped logs and count occurrences
zgrep -h --no-filename '^[^ ]\+' "../logs/apache_wordpress-$code.com.access.log."{2..31}".gz" \
  | awk '{print $1}' \
  | sort \
  | uniq -c \
  | sort -rn \
  >> ../public_html/traffic.txt

# Extract bot names from gzipped logs and count occurrences
zgrep -h --no-filename -i 'bot.*http' "../logs/apache_wordpress-$code.com.access.log."{2..31}".gz" \
  | awk '{for (i=1;i<=NF;i++) if ($i ~ /bot$/) {print $(i-1); break}}' \
  | sort \
  | uniq -c \
  | sort -rn \
  >> ../public_html/traffic.txt

# Count total number of IP addresses
total=$(awk '{s+=$1} END {print s}' ../public_html/traffic.txt)

# Count total number of unique IP addresses
unique=$(wc -l < ../public_html/traffic.txt)

# Print total and unique at the end of the output
echo "Total number of IP addresses: $total" >> ../public_html/traffic.txt
echo "Total number of unique IP addresses: $unique" >> ../public_html/traffic.txt
