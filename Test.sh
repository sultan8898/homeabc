#!/bin/bash

if [ $# -ne 2 ]; then
    echo "Usage: $0 <input> <time>"
    exit 1
fi

input="$1"
time="$2"

case "$input" in
    "php")
        for A in $(ls | awk '{print $NF}'); do
            echo "$A"
            /usr/local/sbin/apm php -s "$A" -l "$time"
        done
        ;;
    "disk1")
        for A in $(ls | awk '{print $NF}'); do
            echo "$A"
            /usr/local/sbin/apm -s "$A" -d
        done
        ;;
    "traffic")
        for A in $(ls | awk '{print $NF}'); do
            echo "$A"
            /usr/local/sbin/apm traffic -s "$A" -l "$time"
        done
        ;;
    "APM")
        for A in $(ls | awk '{print $NF}'); do
            echo "$A"
            sudo /usr/local/sbin/apm traffic -s "$A" -l "$time"
        done
        ;;
    "mysql")
        for A in $(ls | awk '{print $NF}'); do
            echo "$A"
            sudo /usr/local/sbin/apm mysql -s "$A" -l "$time"
        done
        ;;
    "slowphp")
        curl https://raw.githubusercontent.com/ahmedeasypeasy/New-Cpu/main/Cpu.sh | bash
        ;;
    "disk2")
        read -p "Enter directory path (Press enter for current directory): " path
        path=${path:-"."}
        du -sch "$path"/.[!.]* "$path"/* 2>/dev/null | sort -hr | head
        ;;
    *)
        echo "Invalid input"
        ;;
esac
