#!/bin/bash
# monitor-geoip-country.sh
# Continuously monitor nginx-app.status.log and show hit counts per country

LOGFILE="nginx-app.status.log"

tail -f "$LOGFILE" | awk '
$1 != "127.0.0.1" &&
$1 !~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/ {
    ip = $1;
    cmd = (ip ~ /:/ ? "geoiplookup6 " : "geoiplookup ") ip;
    cmd | getline geo;
    close(cmd);
    if (geo ~ /GeoIP Country Edition: ([^,]+),/) {
        match(geo, /GeoIP Country Edition: ([^,]+),/, arr);
        country = arr[1];
        count[country]++;
        system("clear");
        for (c in count) {
            printf "%s > %d hits\n", c, count[c];
        }
    }
    fflush();
}'
