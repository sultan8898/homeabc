#!/bin/bash

echo "Possible inputs:"
echo "1. php"
echo "2. disk1"
echo "3. traffic"
echo "4. APM"
echo "5. mysql"
echo "6. slowphp"
echo "7. disk2"

read -p "Enter input: " input

case "$input" in
    "php")
        read -p "Enter time: " time
        for A in $(ls | awk '{print $NF}'); do echo $A && /usr/local/sbin/apm php -s $A -l $time; done
        ;;
    "disk1")
        for A in $(ls | awk '{print $NF}'); do echo $A && /usr/local/sbin/apm -s $A -d; done
        ;;
    "traffic")
        read -p "Enter time: " time
        for A in $(ls | awk '{print $NF}'); do echo $A && /usr/local/sbin/apm traffic -s $A -l $time; done
        ;;
    "APM")
        read -p "Enter time: " time
        for A in $(ls | awk '{print $NF}'); do echo $A && sudo /usr/local/sbin/apm traffic -s $A -l $time; done
        ;;
    "mysql")
        read -p "Enter time: " time
        for A in $(ls | awk '{print $NF}'); do echo $A && sudo /usr/local/sbin/apm mysql -s $A -l $time; done
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
