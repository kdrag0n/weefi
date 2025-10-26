#!/bin/bash
# optimize mptcp for aggregation

case $CHOICE in
    1)
        SCHEDULER="default"
        DESCRIPTION="max speed"
        ;;
    2)
        SCHEDULER="redundant"
        DESCRIPTION="max reliability"
        ;;
    3)
        SCHEDULER="rr"
        DESCRIPTION="balanced"
        ;;
    4)
        echo "available schedulers: default, redundant, rr, blest" 
        echo ""
        read -p "enter scheduler name: " SCHEDULER
        DESCRIPTION="custom"
        ;;
    *)
        echo "invalid"
        exit 1
        ;;
esac

uci set network.globals.mptcp_enabled='1'
uci set network.globals.mptcp_scheduler="$SCHEDULER"
uci set network.globals.mptcp_checksum='1'
uci set network.globals.mptcp_path_manager='fullmesh'

uci set network.globals.tcp_no_metrics_save='1'
uci set network.globals.tcp_ecn='0'
uci set network.globals.tcp_timestamps='1'
uci set network.globals.tcp_window_scaling='1'
uci set network.globals.tcp_syn_retries='3'
uci set network.globals.tcp_synack_retries='3'

uci commit network

echo "applying to kernel"

sysctl -w net.mptcp.mptcp_enabled=1 2>/dev/null || true
sysctl -w net.mptcp.mptcp_checksum=1 2>/dev/null || true
sysctl -w net.mptcp.mptcp_path_manager=fullmesh 2>/dev/null || true
sysctl -w net.mptcp.mptcp_scheduler=$SCHEDULER 2>/dev/null || true

# TCP
sysctl -w net.ipv4.tcp_no_metrics_save=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_ecn=0 2>/dev/null || true
sysctl -w net.ipv4.tcp_timestamps=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_window_scaling=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_syn_retries=3 2>/dev/null || true
sysctl -w net.ipv4.tcp_synack_retries=3 2>/dev/null || true

echo ""

# adjust interface priorities based on signal quality

WIFI_INTERFACES=$(iw dev 2>/dev/null | grep Interface | awk '{print $2}')

for iface in $WIFI_INTERFACES; do
    if ip link show $iface 2>/dev/null | grep -q "UP"; then
        SIGNAL=$(iwconfig $iface 2>/dev/null | grep "Signal level" | sed 's/.*Signal level=\([-0-9]*\).*/\1/')
        
        if [ -n "$SIGNAL" ] && [ "$SIGNAL" != "0" ]; then
            # calculate priority based on signal
            PRIORITY=$(( (SIGNAL + 90) / 6 + 1 ))
            [ $PRIORITY -lt 1 ] && PRIORITY=1
            [ $PRIORITY -gt 10 ] && PRIORITY=10
            
            # Find WAN name
            WAN_NAME=$(uci show network | grep "ifname='$iface'" | cut -d. -f2 | cut -d= -f1)
            
            if [ -n "$WAN_NAME" ]; then
                echo "  $iface: Signal $SIGNAL dBm → Priority $PRIORITY"
                uci set network.$WAN_NAME.metric="$((100 + 10 - PRIORITY))"
            fi
        fi
    fi
done

uci commit network

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "restarting network"
    /etc/init.d/network reload
    echo "restarted"
fi

echo ""
