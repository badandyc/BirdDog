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
  echo "Mesh adapter not detected yet..."
  sleep 2
done

echo "Mesh adapter detected."

MESH_IP="10.10.20.$((NODE_NUM*10))"

echo "Mesh IP will be $MESH_IP"

echo "Installing mesh join script..."

cat > /usr/local/bin/birddog-mesh-join.sh <<EOF
#!/bin/bash
set -e

echo "BirdDog mesh startup..."

# wait for wlan1
until ip link show wlan1 >/dev/null 2>&1; do
    sleep 1
done

ip link set wlan1 down || true
iw dev wlan1 set type mp
ip link set wlan1 up

sleep 1

iw dev wlan1 mesh join birddog-mesh || true

ip addr add ${MESH_IP}/24 dev wlan1 || true
EOF

chmod +x /usr/local/bin/birddog-mesh-join.sh

echo "Installing mesh systemd service..."

cat > /etc/systemd/system/birddog-mesh.service <<EOF
[Unit]
Description=BirdDog Mesh Join

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

echo ""
echo "====================================="
echo "Mesh network configured"
echo "Node: $HOSTNAME_INPUT"
echo "Interface: wlan1"
echo "IP: $MESH_IP"
echo "Mesh ID: birddog-mesh"
echo "====================================="

echo "Mesh will automatically start at boot."

echo "Verify peers with:"
echo "iw dev wlan1 station dump"

echo ""
echo "Please reboot $HOSTNAME_INPUT now"
