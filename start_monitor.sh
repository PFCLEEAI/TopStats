#!/bin/bash
# Start Floating Monitor with temperature support
# Run this script with: ./start_monitor.sh

cd "$(dirname "$0")"

echo "Starting Floating Monitor..."

# Kill any existing instances
pkill -f FloatingMonitor 2>/dev/null
pkill -f "temp_daemon" 2>/dev/null

# Start the temp daemon in background (needs sudo for Apple Silicon temp)
echo "Starting temperature daemon (requires sudo for CPU temp)..."
sudo bash -c '
TEMP_FILE="/tmp/cpu_temp.txt"
while true; do
    TEMP=$(powermetrics --samplers smc -i1 -n1 2>/dev/null | grep -i "die temperature" | head -1 | awk "{print \$4}")
    if [ -n "$TEMP" ]; then
        echo "$TEMP" > "$TEMP_FILE"
        chmod 644 "$TEMP_FILE"
    fi
    sleep 3
done
' &
TEMP_PID=$!
echo "Temperature daemon started (PID: $TEMP_PID)"

# Wait a moment for first temp reading
sleep 2

# Start the floating monitor
./FloatingMonitor &
MONITOR_PID=$!
echo "Monitor started (PID: $MONITOR_PID)"

echo ""
echo "Monitor is running! Look for the floating bar at the top of your screen."
echo "To quit: Click the gauge icon in menu bar -> Quit Monitor"
echo "To stop temp daemon: sudo pkill -f powermetrics"
