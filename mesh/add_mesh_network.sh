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

echo "Stopping dhcpcd..."

systemctl stop dhcpcd.service 2>/dev/null || true
systemctl disable dhcpcd.service 2>/dev/null || true

echo "Installing mesh runtime script..."

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

# ----------------------------------------------------
# Neighbor cache warmer daemon (runs forever)
# ----------------------------------------------------

echo "Starting neighbor warmer daemon" >> \$LOG

(
while true
do
    for i in \$(seq 10 10 250)
    do
        ping -c1 -W1 10.10.20.\$i >/dev/null 2>&1
    done
    sleep 30
done
) &

echo "Mesh runtime complete" >> \$LOG
EOF

chmod +x /usr/local/bin/birddog-mesh-join.sh


echo "Installing systemd mesh daemon..."

cat <<EOF > /etc/systemd/system/birddog-mesh.service
[Unit]
Description=BirdDog Mesh Runtime
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/birddog-mesh-join.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-mesh
systemctl restart birddog-mesh

echo "Installing mesh CLI tool..."

# (UNCHANGED mesh CLI install — keep your existing block here)

echo ""
echo "====================================="
echo "Mesh subsystem installed"
echo "Node: $HOSTNAME_INPUT"
echo "Interface: wlan1"
echo "IP: $MESH_IP"
echo "====================================="

echo ""
echo "Verify mesh with:"
echo "mesh status"
echo ""
