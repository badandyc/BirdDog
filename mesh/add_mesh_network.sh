#!/bin/bash
set -e

LOG="/opt/birddog/mesh/mesh_install.log"

mkdir -p /opt/birddog/mesh
exec > >(tee -a "$LOG") 2>&1

echo "====================================="
echo "BirdDog Mesh Network Setup"
echo "Install started: $(date)"
echo "====================================="

HOSTNAME_INPUT="$1"

if [[ -z "$HOSTNAME_INPUT" ]]; then
  echo "ERROR: Hostname not provided"
  exit 1
fi

NODE_NUM=$(echo "$HOSTNAME_INPUT" | grep -oE '[0-9]+$')

if [[ -z "$NODE_NUM" ]]; then
  echo "ERROR: Hostname must end in number"
  exit 1
fi

echo ""
echo "Plug in the USB mesh WiFi adapter now."
echo "Expected interface: wlan1"
echo ""

read -p "Press ENTER when adapter is inserted..."

echo "Waiting for wlan1..."

until ip link show wlan1 >/dev/null 2>&1; do
  echo "wlan1 not detected yet..."
  sleep 2
done

echo "wlan1 detected"

MESH_IP="10.10.20.$((NODE_NUM*10))"

echo "Mesh IP: $MESH_IP"

echo ""
echo "Preventing network managers from touching wlan1..."

if ! grep -q "denyinterfaces wlan1" /etc/dhcpcd.conf 2>/dev/null; then
  echo "denyinterfaces wlan1" >> /etc/dhcpcd.conf 2>/dev/null || true
fi

systemctl restart dhcpcd 2>/dev/null || true
systemctl stop wpa_supplicant@wlan1 2>/dev/null || true
systemctl disable wpa_supplicant@wlan1 2>/dev/null || true

echo ""
echo "Creating mesh runtime service..."

cat > /usr/local/bin/birddog-mesh-join.sh <<EOF
#!/bin/bash

LOG="/opt/birddog/mesh/mesh_runtime.log"

mkdir -p /opt/birddog/mesh
exec >> \$LOG 2>&1

echo "================================="
echo "Mesh runtime start \$(date)"
echo "Hostname: \$(hostname)"

sleep 10

until ip link show wlan1 >/dev/null 2>&1; do
    sleep 2
done

ip link set wlan1 down || true
iw dev wlan1 set type mp
ip link set wlan1 up

sleep 2

iw dev wlan1 mesh join birddog-mesh

ip addr add $MESH_IP/24 dev wlan1 2>/dev/null || true

echo "Mesh joined"

#########################################
# SELF HEAL LOOP
#########################################

while true
do

PEERS=\$(iw dev wlan1 station dump | grep Station | wc -l)

if [ "\$PEERS" -eq 0 ]; then

echo "No peers detected — rejoining mesh"

iw dev wlan1 mesh leave || true
sleep 2
iw dev wlan1 mesh join birddog-mesh || true

fi

sleep 30

done

EOF

chmod +x /usr/local/bin/birddog-mesh-join.sh

cat > /etc/systemd/system/birddog-mesh.service <<EOF
[Unit]
Description=BirdDog Mesh Join
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/birddog-mesh-join.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-mesh
systemctl restart birddog-mesh

echo ""
echo "Installing mesh operator command..."

cat > /usr/local/bin/mesh <<'EOF'
#!/bin/bash

CMD="$1"

########################################
# Resolve MAC → hostname
########################################

resolve_mac() {

MAC="$1"

IP=$(ip neigh | grep "$MAC" | awk '{print $1}')

if [[ -n "$IP" ]]; then

LAST=$(echo "$IP" | awk -F. '{print $4}')
NUM=$(printf "%02d" $((LAST/10)))

echo "bdc-$NUM"
return

fi

echo "$MAC"

}

########################################
# HELP MENU
########################################

show_help() {

echo ""
echo "================================="
echo "BirdDog Mesh Command"
echo "================================="
echo ""
echo "mesh status   → mesh health overview"
echo "mesh peers    → RF metrics for peers"
echo "mesh map      → direct neighbors"
echo "mesh scan     → discovered nodes"
echo "mesh graph    → mesh topology"
echo "mesh help     → this menu"
echo ""
echo "================================="
echo ""

}

if [[ -z "$CMD" ]]; then
show_help
exit
fi

########################################
# STATUS
########################################

if [[ "$CMD" == "status" ]]; then

echo "================================="
echo "BirdDog Mesh Status"
echo "Node: $(hostname)"
echo "Time: $(date)"
echo "================================="

TYPE=$(iw dev wlan1 info 2>/dev/null | grep type | awk '{print $2}')
IP=$(ip -4 addr show wlan1 2>/dev/null | awk '/inet / {print $2}')
PEERS=$(iw dev wlan1 station dump 2>/dev/null | grep Station | wc -l)
SIGNAL=$(iw dev wlan1 station dump 2>/dev/null | grep signal | head -1 | awk '{print $2}')

echo "Interface Type : $TYPE"
echo "Mesh IP        : $IP"
echo "Peers          : $PEERS"
echo "Signal         : ${SIGNAL} dBm"

echo ""
echo "Links:"
iw dev wlan1 station dump 2>/dev/null | grep plink

echo "================================="

exit
fi

########################################
# PEERS
########################################

if [[ "$CMD" == "peers" ]]; then

echo "================================="
echo "BirdDog Mesh Peer Details"
echo "================================="

iw dev wlan1 station dump | while read line
do

if [[ $line == Station* ]]; then

MAC=$(echo $line | awk '{print $2}')
NAME=$(resolve_mac "$MAC")

echo ""
echo "Peer: $NAME"

fi

[[ $line == *signal:* ]] && echo "Signal:" $(echo $line | awk '{print $2}') "dBm"
[[ $line == *tx\ bitrate:* ]] && echo "TX Rate:" $(echo $line | awk '{print $3,$4}')
[[ $line == *expected\ throughput:* ]] && echo "Throughput:" $(echo $line | awk '{print $3}')
[[ $line == *airtime*metric:* ]] && echo "Link Metric:" $(echo $line | awk '{print $5}')
[[ $line == *connected\ time:* ]] && echo "Connected:" $(echo $line | awk '{print $3}') "seconds"

done

echo ""
echo "================================="

exit
fi

########################################
# MAP
########################################

if [[ "$CMD" == "map" ]]; then

LOCAL=$(hostname)

echo "================================="
echo "BirdDog Mesh Topology"
echo "================================="

iw dev wlan1 station dump | awk '/Station/ {print $2}' | while read MAC
do
NAME=$(resolve_mac "$MAC")
echo "$LOCAL  <---->  $NAME"
done

echo "================================="

exit
fi

########################################
# SCAN
########################################

if [[ "$CMD" == "scan" ]]; then

echo "================================="
echo "BirdDog Mesh Node Scan"
echo "================================="

ip neigh show dev wlan1 | while read line
do

IP=$(echo $line | awk '{print $1}')

LAST=$(echo "$IP" | awk -F. '{print $4}')
NUM=$(printf "%02d" $((LAST/10)))

echo "bdc-$NUM ($IP)"

done

echo "================================="

exit
fi

########################################
# GRAPH
########################################

if [[ "$CMD" == "graph" ]]; then

LOCAL=$(hostname)

echo "================================="
echo "BirdDog Mesh Graph"
echo "================================="

echo "$LOCAL"
echo "│"

iw dev wlan1 station dump | awk '/Station/ {print $2}' | while read MAC
do
NAME=$(resolve_mac "$MAC")
echo "├── $NAME"
done

echo ""
echo "================================="

exit
fi

########################################
# HELP
########################################

if [[ "$CMD" == "help" ]]; then
show_help
exit
fi

echo "Unknown command: $CMD"
show_help

EOF

chmod +x /usr/local/bin/mesh

echo ""
echo "====================================="
echo "Mesh network install complete"
echo "Node: $HOSTNAME_INPUT"
echo "Mesh IP: $MESH_IP"
echo ""
echo "Commands available:"
echo "mesh"
echo "mesh status"
echo "mesh peers"
echo "mesh map"
echo "mesh scan"
echo "mesh graph"
echo "====================================="
