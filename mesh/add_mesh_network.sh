#!/bin/bash
set -e

LOG="/opt/birddog/mesh/mesh_install.log"

mkdir -p /opt/birddog/mesh

exec > >(tee -a "$LOG") 2>&1

echo "====================================="
echo "BirdDog Mesh Network Setup"
echo "Install started: $(date)"
echo "Log file: $LOG"
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

echo "Waiting for wlan1 interface..."

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
echo "Creating mesh startup script..."

cat > /usr/local/bin/birddog-mesh-join.sh <<EOF
#!/bin/bash

LOG="/opt/birddog/mesh/mesh_runtime.log"

exec >> \$LOG 2>&1

echo "================================="
echo "Mesh runtime start \$(date)"
echo "Hostname: \$(hostname)"

echo "Waiting for wlan1..."

until ip link show wlan1 >/dev/null 2>&1; do
    sleep 1
done

echo "Interface detected"

echo "Initial state:"
ip addr show wlan1
iw dev wlan1 info

echo "Bringing interface down"
ip link set wlan1 down || true

echo "Setting mesh mode"
iw dev wlan1 set type mp

echo "Bringing interface up"
ip link set wlan1 up

sleep 1

echo "Joining mesh"
iw dev wlan1 mesh join birddog-mesh

echo "Assigning IP $MESH_IP"
ip addr add $MESH_IP/24 dev wlan1 || true

echo "Final interface state"
iw dev wlan1 info
ip addr show wlan1

echo "Mesh peers"
iw dev wlan1 station dump

echo "Mesh runtime complete"
EOF

chmod +x /usr/local/bin/birddog-mesh-join.sh

echo "Mesh startup script created:"
ls -l /usr/local/bin/birddog-mesh-join.sh

echo ""
echo "Creating systemd service..."

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

echo "Service file contents:"
cat /etc/systemd/system/birddog-mesh.service

echo ""
echo "Reloading systemd..."

systemctl daemon-reload

echo "Enabling service..."

systemctl enable birddog-mesh

echo "Starting service..."

systemctl start birddog-mesh || true

echo ""
echo "Service status after start:"
systemctl status birddog-mesh || true

echo ""
echo "====================================="
echo "Mesh network install complete"
echo "Node: $HOSTNAME_INPUT"
echo "Interface: wlan1"
echo "Mesh IP: $MESH_IP"
echo ""
echo "Install log: /opt/birddog/mesh/mesh_install.log"
echo "Runtime log: /opt/birddog/mesh/mesh_runtime.log"
echo "====================================="
