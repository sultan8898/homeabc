#!/bin/bash
# monitor-geoip.sh
# Continuously monitor nginx-app.status.log and show external IPs with GeoIP info

LOGFILE="nginx-app.status.log"

tail -f "$LOGFILE" | awk '
  $1 != "127.0.0.1" &&
  $1 !~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/ {
    print $1;
    cmd = ($1 ~ /:/ ? "geoiplookup6 " : "geoiplookup ") $1;
    system(cmd);
  }
' | grep -v "IP Address not found"
