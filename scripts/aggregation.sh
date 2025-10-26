#!/bin/bash
# init setup script for WiFi aggregation on Raspberry Pi 5
# configs MPTCP and preps system for multiple WAN interfaces
set -e
MODEL=$(cat /proc/device-tree/model 2>/dev/null || echo "unknown")
if [[ ! "$MODEL" =~ "Raspberry Pi 5" ]]; then
    echo "detected: $MODEL"
    read -p "y/n" -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi
if [ ! -f /etc/openmptcprouter-version ]; then
    echo "openmptcprouter not detected"
    echo "do firmware install"
    exit 1
fi
WIFI_INTERFACES=$(iw dev | grep Interface | awk '{print $2}')
WIFI_COUNT=$(echo "$WIFI_INTERFACES" | wc -l)
echo "Found $WIFI_COUNT WiFi interface(s)"
for iface in $WIFI_INTERFACES; do
    echo "  - $iface"
done
echo ""
if [ $WIFI_COUNT -lt 2 ]; then
    echo "only $WIFI_COUNT WiFi interface found"
    echo ""
fi

uci set network.globals.mptcp_enabled='1'
uci set network.globals.mptcp_path_manager='fullmesh'
uci set network.globals.mptcp_scheduler='redundant'
uci set network.globals.mptcp_checksum='1'
uci set network.globals.tcp_no_metrics_save='1'
uci set network.globals.tcp_ecn='0'
uci commit network
echo "configured"

for iface in $WIFI_INTERFACES; do
    if [ -d "/sys/class/net/$iface" ]; then
        iwconfig $iface power off 2>/dev/null || true
        echo "  - $iface: power management disabled"
    fi
done
echo ""

mkdir -p /etc/openmptcprouter/wifi
opkg update
opkg install iwinfo iw wireless-tools 2>/dev/null || echo "some already installed"
cat > /etc/openmptcprouter/wifi/status.json <<EOF
{
  "setup_date": "$(date -Iseconds)",
  "wifi_interfaces": $(echo "$WIFI_INTERFACES" | jq -R -s -c 'split("\n")[:-1]'),
  "mptcp_scheduler": "redundant",
  "configured_wans": []
}
EOF
echo "   ./add-wifi-wan.sh wlan0 \"YourSSID\" \"password\""
