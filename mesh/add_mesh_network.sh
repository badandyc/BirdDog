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

echo "Hostname argument: $HOSTNAME_INPUT"

if [[ -z "$HOSTNAME_INPUT" ]]; then
  echo "ERROR: Hostname not provided"
  exit 1
fi

NODE_NUM=$(echo "$HOSTNAME_INPUT" | grep -oE '[0-9]+$')

echo "Parsed node number: $NODE_NUM"

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

echo "Current interface state:"
ip addr show wlan1 || true
iw dev wlan1 info || true

MESH_IP="10.10.20.$((NODE_NUM*10))"

echo "Calculated mesh IP: $MESH_IP"

echo ""
echo "Configuring network managers to ignore wlan1..."

if ! grep -q "denyinterfaces wlan1" /etc/dhcpcd.conf; then
  echo "denyinterfaces wlan1" >> /etc/dhcpcd.conf
  echo "Added wlan1 to dhcpcd deny list"
fi

systemctl restart dhcpcd || true

systemctl stop wpa_supplicant@wlan1 2>/dev/null || true
systemctl disable wpa_supplicant@wlan1 2>/dev/null || true

echo "wpa_supplicant disabled for wlan1"

echo ""
echo "Creating mesh runtime script..."

cat > /usr/local/bin/birddog-mesh-join.sh <<EOF
#!/bin/bash

LOG="/opt/birddog/mesh/mesh_runtime.log"

mkdir -p /opt/birddog/mesh

exec >> \$LOG 2>&1

echo "================================="
echo "Mesh runtime start \$(date)"
echo "Hostname: \$(hostname)"

echo "Waiting for USB WiFi initialization..."
sleep 10

echo "Waiting for wlan1..."

until ip link show wlan1 >/dev/null 2>&1; do
    sleep 2
done

echo "Interface detected"

echo "Initial interface state:"
ip addr show wlan1
iw dev wlan1 info

echo "Resetting interface..."
ip link set wlan1 down || true

echo "Setting mesh mode..."
iw dev wlan1 set type mp

echo "Bringing interface up..."
ip link set wlan1 up

sleep 2

echo "Joining mesh..."
iw dev wlan1 mesh join birddog-mesh

echo "Assigning IP $MESH_IP"
ip addr add $MESH_IP/24 dev wlan1 2>/dev/null || true

echo "Final interface state:"
iw dev wlan1 info
ip addr show wlan1

echo "Mesh peers:"
iw dev wlan1 station dump

echo "Mesh runtime complete"
EOF

chmod +x /usr/local/bin/birddog-mesh-join.sh

echo "Mesh runtime script installed."

echo ""
echo "Creating mesh systemd service..."

cat > /etc/systemd/system/birddog-mesh.service <<EOF
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

echo "Reloading systemd..."

systemctl daemon-reload

echo "Enabling mesh service..."

systemctl enable birddog-mesh

echo "Restarting mesh service..."

systemctl restart birddog-mesh

echo ""
echo "Service status:"
systemctl status birddog-mesh || true

echo ""
echo "Installing BirdDog mesh status command..."

cat > /usr/local/bin/mesh <<'EOF'
#!/bin/bash

CMD="$1"

if [[ "$CMD" != "status" ]]; then
    echo "Usage: mesh status"
    exit 1
fi

echo "================================="
echo "BirdDog Mesh Status"
echo "Node: $(hostname)"
echo "Time: $(date)"
echo "================================="

echo ""
echo "Interface Type:"
iw dev wlan1 info | grep type

echo ""
echo "IP Address:"
ip -4 addr show wlan1 | awk '/inet / {print $2}'

echo ""
echo "Interface State:"
ip addr show wlan1 | grep wlan1

echo ""
echo "Peer Count:"
PEERS=$(iw dev wlan1 station dump | grep Station | wc -l)
echo "$PEERS peers"

echo ""
echo "Peers:"
iw dev wlan1 station dump | awk '/Station/ {print $2}'

echo ""
echo "Link State:"
iw dev wlan1 station dump | grep plink

echo "================================="
EOF

chmod +x /usr/local/bin/mesh

echo "Mesh command installed: mesh status"

echo ""
echo "====================================="
echo "Mesh network install complete"
echo "Node: $HOSTNAME_INPUT"
echo "Mesh IP: $MESH_IP"
echo ""
echo "Install log: /opt/birddog/mesh/mesh_install.log"
echo "Runtime log: /opt/birddog/mesh/mesh_runtime.log"
echo "====================================="

echo ""
echo "Verify mesh with:"
echo "mesh status"
echo "ping 10.10.20.X"

echo ""
echo "Reboot to verify persistence."
