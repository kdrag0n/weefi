#!/bin/bash

VPS_IP=${VPS_IP:-"143.198.151.102"}
VPS_PORT=${VPS_PORT:-"5202"}
TEST_DURATION=${TEST_DURATION:-10}
echo "IP:        $VPS_IP"
echo "Port:      $VPS_PORT"
echo "Duration: ${TEST_DURATION}s"

if ! command -v iperf3 &>/dev/null; then
    echo "iperf3 not found"
    opkg update && opkg install iperf3
fi

WIFI_INTERFACES=$(iw dev 2>/dev/null | grep Interface | awk '{print $2}')
CONNECTED_INTERFACES=""

declare -A SPEEDS

for iface in $WIFI_INTERFACES; do
    if ip link show $iface 2>/dev/null | grep -q "UP"; then
        IP=$(ip addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        
        if [ -n "$IP" ]; then
            CONNECTED_INTERFACES="$CONNECTED_INTERFACES $iface"
            echo "testing $iface ($IP)..."
            if ping -I $iface -c 3 -W 2 8.8.8.8 &>/dev/null; then                
                echo "running speed test..."
                RESULT=$(iperf3 -c $VPS_IP -p $VPS_PORT -B $IP -t $TEST_DURATION -J 2>/dev/null)
                if [ $? -eq 0 ]; then
                    SPEED=$(echo "$RESULT" | jq -r '.end.sum_received.bits_per_second' 2>/dev/null)
                    SPEED_MBPS=$(echo "scale=2; $SPEED / 1000000" | bc 2>/dev/null || echo "0")
                    SPEEDS[$iface]=$SPEED_MBPS
                    echo "speed: ${SPEED_MBPS} Mbps"
                else
                    echo "speed test failed"
                    SPEEDS[$iface]=0
                fi
            else
                SPEEDS[$iface]=0
            fi
            SIGNAL=$(iwconfig $iface 2>/dev/null | grep "signal level" | sed 's/.*Signal level=\([-0-9]*\).*/\1/')
            if [ -n "$SIGNAL" ]; then
                echo "signal: $SIGNAL dBm"
            fi
            echo ""
        fi
    fi
done

if [ -z "$CONNECTED_INTERFACES" ]; then
    echo "no WiFi interfaces connected"
    exit 1
fi
RESULT=$(iperf3 -c $VPS_IP -p $VPS_PORT -P 8 -t $TEST_DURATION -J 2>/dev/null)
if [ $? -eq 0 ]; then
    AGG_SPEED=$(echo "$RESULT" | jq -r '.end.sum_received.bits_per_second' 2>/dev/null)
    AGG_SPEED_MBPS=$(echo "scale=2; $AGG_SPEED / 1000000" | bc 2>/dev/null || echo "0")
    echo "aggregate speed: ${AGG_SPEED_MBPS} Mbps"
else
    echo "aggregate test failed"
    AGG_SPEED_MBPS=0
fi

read -p "run failover test? y/n " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    FIRST_IFACE=$(echo $CONNECTED_INTERFACES | awk '{print $1}')
    echo "disabling $FIRST_IFACE temporarily"
    ip link set $FIRST_IFACE down
    sleep 2
    echo "testing connectivity with 1 interface down"
    if ping -c 3 8.8.8.8 &>/dev/null; then
        echo "failover successful"
    else
        echo "failover failed"
    fi
    echo "re-enabling $FIRST_IFACE..."
    ip link set $FIRST_IFACE up
    sleep 3
else
    echo "skipped failover test"
fi

EXPECTED_TOTAL=0
for iface in $CONNECTED_INTERFACES; do
    SPEED=${SPEEDS[$iface]:-0}
    echo "$iface: ${SPEED} Mbps"
    EXPECTED_TOTAL=$(echo "$EXPECTED_TOTAL + $SPEED" | bc 2>/dev/null)
done
echo ""
echo "expected:  ${EXPECTED_TOTAL} Mbps"
echo "actual: ${AGG_SPEED_MBPS} Mbps"

if [ $(echo "$AGG_SPEED_MBPS > 0" | bc) -eq 1 ]; then
    EFFICIENCY=$(echo "scale=1; ($AGG_SPEED_MBPS / $EXPECTED_TOTAL) * 100" | bc 2>/dev/null || echo "0")
    echo "efficiency:      ${EFFICIENCY}%"
    echo ""
    
    if [ $(echo "$EFFICIENCY >= 85" | bc) -eq 1 ]; then
        echo "great"
    elif [ $(echo "$EFFICIENCY >= 70" | bc) -eq 1 ]; then
        echo "good"
    elif [ $(echo "$EFFICIENCY >= 50" | bc) -eq 1 ]; then
        echo "needs optimization"
    else
        echo "poor, check config"
    fi
fi
AVG_SPEED=$(echo "$EXPECTED_TOTAL / $(echo $CONNECTED_INTERFACES | wc -w)" | bc 2>/dev/null)

if [ $(echo "$EFFICIENCY < 75" | bc 2>/dev/null) -eq 1 ]; then
    echo "     ./optimize-wifi-mptcp.sh"
fi
