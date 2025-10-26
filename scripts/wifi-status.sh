#!/bin/bash
MPTCP_ENABLED=$(uci get network.globals.mptcp_enabled 2>/dev/null || echo "unknown")
MPTCP_SCHEDULER=$(uci get network.globals.mptcp_scheduler 2>/dev/null || echo "unknown")
echo "enabled:   $MPTCP_ENABLED"
echo "scheduler: $MPTCP_SCHEDULER"

WIFI_INTERFACES=$(iw dev | grep Interface | awk '{print $2}')
for iface in $WIFI_INTERFACES; do
    echo "interface: $iface"
    if ip link show $iface 2>/dev/null | grep -q "UP"; then
        echo "status: UP"
        IP=$(ip addr show $iface 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
        if [ -n "$IP" ]; then
            echo "  IP:        $IP"
        else
            echo "  IP:        not assigned"
        fi
        if command -v iwconfig &>/dev/null; then
            SSID=$(iwconfig $iface 2>/dev/null | grep ESSID | cut -d'"' -f2)
            SIGNAL=$(iwconfig $iface 2>/dev/null | grep "signal level" | sed 's/.*Signal level=\([-0-9]*\).*/\1/')
            BITRATE=$(iwconfig $iface 2>/dev/null | grep "bit rate" | sed 's/.*Bit Rate[:=]\([^ ]*\).*/\1/')            
            [ -n "$SSID" ] && echo "  SSID:      $SSID"
            [ -n "$SIGNAL" ] && echo "  Signal:    $SIGNAL dBm"
            [ -n "$BITRATE" ] && echo "  Bit Rate:  $BITRATE"
        fi
        WAN_NAME=$(uci show network | grep "ifname='$iface'" | cut -d. -f2 | cut -d= -f1)
        if [ -n "$WAN_NAME" ]; then
            MULTIPATH=$(uci get network.$WAN_NAME.multipath 2>/dev/null || echo "off")
            echo "  MPTCP:     $MULTIPATH"
        fi
        RX_BYTES=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        TX_BYTES=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        RX_MB=$((RX_BYTES / 1024 / 1024))
        TX_MB=$((TX_BYTES / 1024 / 1024))
        echo "  traffic:   ↓ ${RX_MB}MB  ↑ ${TX_MB}MB"
        
    else
        echo "status: down"
    fi
done

if [ -f /proc/net/mptcp_net/sndbuf ]; then
    echo "active MPTCP connections:"
    cat /proc/net/mptcp_net/sndbuf 2>/dev/null | head -20
elif command -v ss &>/dev/null; then
    echo ""
    MPTCP_CONNS=$(ss -tn | grep -c "ESTAB" || echo 0)
    echo "TCP connections: $MPTCP_CONNS"
fi
if command -v omr-vps &>/dev/null; then
    omr-vps status 2>/dev/null || echo "VPN status unknown"
elif [ -f /tmp/omr-vps-status ]; then
    cat /tmp/omr-vps-status
else
    echo "check web interface"
fi

ACTIVE_WIFI=$(echo "$WIFI_INTERFACES" | wc -l)
UP_WIFI=0
for iface in $WIFI_INTERFACES; do
    if ip link show $iface 2>/dev/null | grep -q "UP"; then
        if ip addr show $iface 2>/dev/null | grep -q "inet "; then
            UP_WIFI=$((UP_WIFI + 1))
        fi
    fi
done
echo "$ACTIVE_WIFI total, $UP_WIFI connected"
