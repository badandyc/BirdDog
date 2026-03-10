#!/bin/bash
set -e

echo "====================================="
echo "BirdDog Mesh Network Setup"
echo "====================================="

HOSTNAME_INPUT="$1"

if [[ -z "$HOSTNAME_INPUT" ]]; then
  echo "Hostname not provided"
  exit 1
fi

NODE_NUM=$(echo "$HOSTNAME_INPUT" | grep -oE '[0-9]+$')

if [[ -z "$NODE_NUM" ]]; then
  echo "Hostname must end in number"
  exit 1
fi

echo ""
echo "Plug in the USB mesh WiFi adapter now."
echo "Expected interface: wlan1"
echo ""

read -p "Press ENTER when adapter is inserted..."

echo "Waiting for wlan1..."

until ip link show wlan1 >/dev/null 2>&1; do
  sleep 2
done

echo "wlan1 detected"

MESH_IP="10.10.20.$((NODE_NUM*10))"

echo "Mesh IP: $MESH_IP"

mkdir -p /opt/birddog/mesh

INSTALL_LOG="/opt/birddog/mesh/mesh_install.log"
RUNTIME_LOG="/opt/birddog/mesh/mesh_runtime.log"

echo "=====================================" > "$INSTALL_LOG"
echo "BirdDog Mesh Install $(date)" >> "$INSTALL_LOG"
echo "Node: $HOSTNAME_INPUT" >> "$INSTALL_LOG"
echo "=====================================" >> "$INSTALL_LOG"

echo "Stopping dhcpcd (if present)..."

systemctl stop dhcpcd.service 2>/dev/null || true
systemctl disable dhcpcd.service 2>/dev/null || true

echo "Creating mesh runtime service..."

cat <<EOF > /usr/local/bin/birddog-mesh-join.sh
#!/bin/bash

LOG="/opt/birddog/mesh/mesh_runtime.log"

echo "=================================" >> \$LOG
echo "Mesh runtime start \$(date)" >> \$LOG
echo "Hostname: \$(hostname)" >> \$LOG

sleep 10

until ip link show wlan1 >/dev/null 2>&1; do
    sleep 1
done

ip link set wlan1 down >> \$LOG 2>&1 || true
iw dev wlan1 set type mp >> \$LOG 2>&1
ip link set wlan1 up >> \$LOG 2>&1

sleep 2

iw dev wlan1 mesh join birddog-mesh >> \$LOG 2>&1 || true
ip addr add $MESH_IP/24 dev wlan1 >> \$LOG 2>&1 || true

echo "Interface state:" >> \$LOG
ip addr show wlan1 >> \$LOG
iw dev wlan1 info >> \$LOG

echo "Peers:" >> \$LOG
iw dev wlan1 station dump >> \$LOG

echo "Mesh runtime complete" >> \$LOG
EOF

chmod +x /usr/local/bin/birddog-mesh-join.sh

cat <<EOF > /etc/systemd/system/birddog-mesh.service
[Unit]
Description=BirdDog Mesh Join
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/birddog-mesh-join.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-mesh
systemctl start birddog-mesh

echo "Installing mesh command..."

cat <<'EOF' > /usr/local/bin/mesh
#!/bin/bash

resolve_peer() {

MAC=$1

IP=$(ip neigh | grep $MAC | awk '{print $1}' | head -n1)

if [ -n "$IP" ]; then
    HOST=$(avahi-resolve-address $IP 2>/dev/null | awk '{print $2}' | sed 's/.local//')
    if [ -n "$HOST" ]; then
        echo $HOST
        return
    fi
fi

echo $MAC

}

mesh_table() {

echo ""
echo "Node        IP              Signal      Rate       Metric"
echo "--------------------------------------------------------------"

SELF_NODE=$(hostname)

SELF_IP=$(ip -4 addr show wlan1 | grep inet | awk '{print $2}' | cut -d/ -f1)

printf "%-12s %-15s %-10s %-10s %-10s\n" "$SELF_NODE" "$SELF_IP" "self" "-" "-"

iw dev wlan1 station dump | grep Station | awk '{print $2}' | while read MAC
do

HOST=$(resolve_peer $MAC)

IP=$(ip neigh | grep $MAC | awk '{print $1}' | head -n1)

SIGNAL=$(iw dev wlan1 station dump | grep -A20 $MAC | grep signal: | awk '{print $2}' | head -n1)

RATE=$(iw dev wlan1 station dump | grep -A20 $MAC | grep bitrate | awk '{print $3}' | head -n1)

METRIC=$(iw dev wlan1 station dump | grep -A20 $MAC | grep metric | awk '{print $4}' | head -n1)

printf "%-12s %-15s %-10s %-10s %-10s\n" "$HOST" "$IP" "$SIGNAL dBm" "$RATE" "$METRIC"

done

echo ""

}

multi_hop_map() {

echo ""
echo "Mesh Routes"
echo "--------------------------------"

ip route show dev wlan1 | while read line
do

DEST=$(echo $line | awk '{print $1}')
NEXTHOP=$(echo $line | grep -o 'via [0-9.]*' | awk '{print $2}')

if [ -n "$NEXTHOP" ]; then

HOST=$(avahi-resolve-address $DEST 2>/dev/null | awk '{print $2}' | sed 's/.local//')
NEXT=$(avahi-resolve-address $NEXTHOP 2>/dev/null | awk '{print $2}' | sed 's/.local//')

echo "$HOST  ->  $NEXT"

fi

done

echo ""

}

case "$1" in

status)

echo "================================="
echo "BirdDog Mesh Status"
echo "Node: $(hostname)"
echo "Time: $(date)"
echo "================================="

TYPE=$(iw dev wlan1 info 2>/dev/null | grep type | awk '{print $2}')
IP=$(ip -4 addr show wlan1 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
PEERS=$(iw dev wlan1 station dump | grep Station | wc -l)

echo "Interface Type : $TYPE"
echo "Mesh IP        : $IP"
echo "Peers          : $PEERS"

mesh_table

;;

peers)

echo "================================="
echo "BirdDog Mesh Peer Details"
echo "================================="

iw dev wlan1 station dump | grep Station | awk '{print $2}' | while read MAC
do

HOST=$(resolve_peer $MAC)

SIGNAL=$(iw dev wlan1 station dump | grep -A20 $MAC | grep signal: | awk '{print $2}' | head -n1)

RATE=$(iw dev wlan1 station dump | grep -A20 $MAC | grep bitrate | awk '{print $3}' | head -n1)

METRIC=$(iw dev wlan1 station dump | grep -A20 $MAC | grep metric | awk '{print $4}' | head -n1)

echo ""
echo "Peer: $HOST"
echo "MAC: $MAC"
echo "Signal: $SIGNAL dBm"
echo "TX Rate: $RATE"
echo "Link Metric: $METRIC"

done

echo ""

;;

map)

echo "================================="
echo "BirdDog Mesh Topology"
echo "================================="

SELF=$(hostname)

iw dev wlan1 station dump | grep Station | awk '{print $2}' | while read MAC
do

HOST=$(resolve_peer $MAC)

echo "$SELF  <---->  $HOST"

done

multi_hop_map

;;

graph)

echo "================================="
echo "BirdDog Mesh Graph"
echo "================================="

SELF=$(hostname)

echo "$SELF"
echo "│"

iw dev wlan1 station dump | grep Station | awk '{print $2}' | while read MAC
do

HOST=$(resolve_peer $MAC)

echo "├── $HOST"

done

multi_hop_map

;;

scan)

echo "Scanning mesh neighbors..."
iw dev wlan1 scan | grep SSID

;;

""|help)

echo ""
echo "================================="
echo "BirdDog Mesh Command"
echo "================================="
echo ""
echo "mesh status   → mesh health overview"
echo "mesh peers    → RF metrics"
echo "mesh map      → direct + multi-hop"
echo "mesh graph    → topology tree"
echo "mesh scan     → discovered nodes"
echo "mesh help     → this menu"
echo ""
echo "================================="
echo ""

;;

*)

echo "Unknown command"

;;

esac
EOF

chmod +x /usr/local/bin/mesh

echo ""
echo "====================================="
echo "Mesh network configured"
echo "Node: $HOSTNAME_INPUT"
echo "Interface: wlan1"
echo "IP: $MESH_IP"
echo "Mesh ID: birddog-mesh"
echo "====================================="

echo ""
echo "Verify mesh with:"
echo "mesh status"
echo ""
