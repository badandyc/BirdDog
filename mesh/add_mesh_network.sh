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

if ! grep -q "denyinterfaces wlan1" /etc/dhcpcd.conf; then
  echo "denyinterfaces wlan1" >> /etc/dhcpcd.conf
fi

systemctl restart dhcpcd || true

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

echo "Configuring mesh interface..."

ip link set wlan1 down || true
iw dev wlan1 set type mp
ip link set wlan1 up

sleep 2

iw dev wlan1 mesh join birddog-mesh

ip addr add $MESH_IP/24 dev wlan1 2>/dev/null || true

echo "Mesh joined"

################################################
# SELF HEAL LOOP
################################################

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

resolve_mac() {

MAC="$1"

IP=$(ip neigh | grep "$MAC" | awk '{print $1}')

if [[ -n "$IP" ]]; then
    HOST=$(getent hosts "$IP" | awk '{print $2}' | cut -d'.' -f1)
    if [[ -n "$HOST" ]]; then
        echo "$HOST"
        return
    fi
fi

echo "$MAC"

}

###################################
# STATUS
###################################

if [[ "$CMD" == "status" ]]; then

echo "================================="
echo "BirdDog Mesh Status"
echo "Node: $(hostname)"
echo "Time: $(date)"
echo "================================="

iw dev wlan1 info | grep type

echo ""
echo "IP Address:"
ip -4 addr show wlan1 | awk '/inet / {print $2}'

echo ""
echo "Peer Count:"
PEERS=$(iw dev wlan1 station dump | grep Station | wc -l)
echo "$PEERS peers"

echo ""
echo "Links:"
iw dev wlan1 station dump | grep plink

echo "================================="

exit
fi

###################################
# PEERS
###################################

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

if [[ $line == *signal:* ]]; then
echo "Signal:" $(echo $line | awk '{print $2}') "dBm"
fi

if [[ $line == *tx\ bitrate:* ]]; then
echo "TX Rate:" $(echo $line | awk '{print $3,$4}')
fi

if [[ $line == *expected\ throughput:* ]]; then
echo "Throughput:" $(echo $line | awk '{print $3}')
fi

if [[ $line == *airtime*metric:* ]]; then
echo "Link Metric:" $(echo $line | awk '{print $5}')
fi

if [[ $line == *connected\ time:* ]]; then
echo "Connected:" $(echo $line | awk '{print $3}') "seconds"
fi

done

echo ""
echo "================================="

exit
fi

###################################
# MAP
###################################

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

###################################
# SCAN
###################################

if [[ "$CMD" == "scan" ]]; then

echo "================================="
echo "BirdDog Mesh Node Scan"
echo "================================="

ip neigh show dev wlan1 | while read line
do

IP=$(echo $line | awk '{print $1}')
MAC=$(echo $line | awk '{print $5}')

HOST=$(getent hosts "$IP" | awk '{print $2}' | cut -d'.' -f1)

if [[ -z "$HOST" ]]; then
HOST="$MAC"
fi

echo "$HOST  ($IP)"

done

echo "================================="

exit
fi

echo "Usage:"
echo "mesh status"
echo "mesh peers"
echo "mesh map"
echo "mesh scan"

EOF

chmod +x /usr/local/bin/mesh

echo ""
echo "====================================="
echo "Mesh network install complete"
echo "Node: $HOSTNAME_INPUT"
echo "Mesh IP: $MESH_IP"
echo ""
echo "Commands:"
echo "mesh status"
echo "mesh peers"
echo "mesh map"
echo "mesh scan"
echo "====================================="
