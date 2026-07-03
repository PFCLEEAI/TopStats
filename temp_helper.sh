#!/bin/bash
# Temperature helper for Apple Silicon
# Runs with sudo to read CPU temperature and writes to a file

TEMP_FILE="/tmp/cpu_temp.txt"

while true; do
    # Get temperature from powermetrics
    TEMP=$(sudo powermetrics --samplers smc -i1 -n1 2>/dev/null | grep -i "CPU die temperature" | awk '{print $4}')

    if [ -z "$TEMP" ]; then
        # Try alternative method
        TEMP=$(sudo powermetrics --samplers thermal -i1 -n1 2>/dev/null | grep -i "temperature" | head -1 | grep -oE '[0-9]+\.[0-9]+')
    fi

    if [ -n "$TEMP" ]; then
        echo "$TEMP" > "$TEMP_FILE"
    fi

    sleep 3
done
