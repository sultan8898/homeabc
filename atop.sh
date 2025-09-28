#!/bin/bash

ATOP_DIR="/var/log/atop"
cd "$ATOP_DIR" || { echo "Failed to access $ATOP_DIR"; exit 1; }

# Find all files matching atop_*.1 pattern
for log in atop_*.1; do
  # Skip if not a regular file
  [[ -f "$log" ]] || continue
  echo "Processing $log..."

  atop -r "$log" -b 00:00 -e 23:59 2>/dev/null | awk '
  BEGIN {
    max_usage = 0
    max_mem_used = 0
  }
  /^ATOP -/ {
    date = $4
    time = $5
  }
  /^CPU \|/ {
    sub(/%/, "", $4); user = $4 + 0
    sub(/%/, "", $6); sys = $6 + 0
    sub(/%/, "", $8); idle = $8 + 0
    usage = user + sys
    total_user += user
    total_sys += sys
    total_idle += idle
    cpu_count++
    if (usage > max_usage) {
      max_usage = usage
      max_time = time
      max_date = date
    }
  }
  /^MEM \|/ {
    mem_tot = mem_free = mem_cache = mem_buff = 0
    if (match($0, /tot[[:space:]]+([0-9.]+)([MG])/, m)) {
      mem_tot = (m[2] == "G") ? m[1] * 1024 : m[1] + 0
    }
    if (match($0, /free[[:space:]]+([0-9.]+)([MG])/, m)) {
      mem_free = (m[2] == "G") ? m[1] * 1024 : m[1] + 0
    }
    if (match($0, /cache[[:space:]]+([0-9.]+)([MG])/, m)) {
      mem_cache = (m[2] == "G") ? m[1] * 1024 : m[1] + 0
    }
    if (match($0, /buff[[:space:]]+([0-9.]+)([MG])/, m)) {
      mem_buff = (m[2] == "G") ? m[1] * 1024 : m[1] + 0
    }
    mem_used = mem_tot - mem_free - mem_cache - mem_buff
    total_mem_used += mem_used
    total_mem_free += mem_free
    mem_count++
    if (mem_used > max_mem_used) {
      max_mem_used = mem_used
      max_mem_time = time
      max_mem_date = date
    }
  }
  END {
    if (cpu_count > 0) {
      avg_usage = (total_user + total_sys) / cpu_count
      avg_idle = total_idle / cpu_count
      printf " Avg CPU (user+sys): %.2f%%\n", avg_usage
      printf " Avg idle: %.2f%%\n", avg_idle
      printf " Max CPU (user+sys): %.2f%% at %s %s\n", max_usage, max_date, max_time
    } else {
      print " No CPU data found."
    }

    if (mem_count > 0) {
      avg_mem_used = total_mem_used / mem_count
      avg_mem_free = total_mem_free / mem_count
      printf " Avg Mem Used: %.2f MB\n", avg_mem_used
      printf " Avg Mem Free: %.2f MB\n", avg_mem_free
      printf " Max Mem Used: %.2f MB at %s %s\n\n", max_mem_used, max_mem_date, max_mem_time
    } else {
      print " No Memory data found.\n"
    }
  }'
done
