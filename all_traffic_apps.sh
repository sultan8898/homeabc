#!/usr/bin/env bash
# tail all status logs, tag with app name, group by country
shopt -s nullglob
LOGS=(/home/master/applications/*/logs/nginx-app.status.log)
[ ${#LOGS[@]} -eq 0 ] && { echo "No logs found"; exit 1; }
# tail each file, prefix app name, aggregate in awk
for f in "${LOGS[@]}"; do
  app="$(basename "$(dirname "$(dirname "$f")")")"
  stdbuf -oL -eL tail -n0 -F "$f" | awk -v app="$app" '{print app,$1}' &
done |
awk '
function is_private(ip) {
  return ip ~ /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/ || ip=="-"
}
function cc_lookup(ip, out, cc) {
  if (ip in cc_cache) return cc_cache[ip]
  cmd = (ip ~ /:/ ? "geoiplookup6 " : "geoiplookup ") ip
  cmd | getline out; close(cmd)
  cc="Unknown"
  if (match(out, /Country (V6 )?Edition: ([A-Z]{2}),/, m)) cc=m[2]
  cc_cache[ip]=cc
  return cc
}
function print_report() {
  system("clear")
  print strftime("Updated %Y-%m-%d %H:%M:%S")
  for (key in count) {
    split(key,a,SUBSEP)
    printf "%-15s %-3s %5d hits\n", a[1], a[2], count[key]
  }
}
{
  app=$1; ip=$2
  if (is_private(ip)) next
  cc=cc_lookup(ip)
  count[app,cc]++
  now=systime()
  if (now-last>=5) { print_report(); last=now }
}
'
