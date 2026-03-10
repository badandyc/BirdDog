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

echo "Configuring mesh interface..."

ip link set wlan1 down || true
iw dev wlan1 set type mp || true
ip link set wlan1 up || true

echo "Joining mesh network..."

iw dev wlan1 mesh join birddog-mesh || true

echo "Mesh joined."

MESH_IP="10.10.20.$((NODE_NUM*10))"

echo "Mesh IP will be $MESH_IP"

mkdir -p /etc/systemd/network

cat > /etc/systemd/network/30-mesh.network <<EOF
[Match]
Name=wlan1

[Network]
Address=${MESH_IP}/24
ConfigureWithoutCarrier=yes
EOF

systemctl enable systemd-networkd
systemctl restart systemd-networkd

echo "Installing persistent mesh service..."

cat > /etc/systemd/system/birddog-mesh.service <<EOF
[Unit]
Description=BirdDog Mesh Join
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link set wlan1 down
ExecStart=/usr/sbin/iw dev wlan1 set type mp
ExecStart=/usr/sbin/ip link set wlan1 up
ExecStart=/usr/sbin/iw dev wlan1 mesh join birddog-mesh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-mesh || true

echo ""
echo "====================================="
echo "Mesh network configured"
echo "Node: $HOSTNAME_INPUT"
echo "Interface: wlan1"
echo "IP: $MESH_IP"
echo "Mesh ID: birddog-mesh"
echo "====================================="

echo "Mesh will automatically start at boot."
echo "You can verify peers with:"
echo "iw dev wlan1 station dump"

echo ""
echo "Please reboot $HOSTNAME_INPUT now"
