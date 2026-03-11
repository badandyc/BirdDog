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
echo ""

read -p "Press ENTER when adapter is inserted..."

until ip link show wlan1 >/dev/null 2>&1; do
  sleep 1
done

echo "wlan1 detected"

MESH_IP="10.10.20.$((NODE_NUM*10))"

mkdir -p /opt/birddog/mesh
LOG="/opt/birddog/mesh/mesh_runtime.log"

echo "Stopping dhcpcd..."
systemctl stop dhcpcd 2>/dev/null || true
systemctl disable dhcpcd 2>/dev/null || true


echo "Installing mesh watchdog..."

cat <<EOF > /usr/local/bin/birddog-meshd.sh
#!/bin/bash

LOG="/opt/birddog/mesh/mesh_runtime.log"
MESH_IP="$MESH_IP"

log() {
    echo "\$(date '+%H:%M:%S')  \$1" >> \$LOG
}

log "Mesh watchdog start"

while true
do

    if ! ip link show wlan1 >/dev/null 2>&1; then
        sleep 2
        continue
    fi

    rfkill unblock wifi 2>/dev/null || true

    TYPE=\$(iw dev wlan1 info 2>/dev/null | awk '/type/ {print \$2}')

    if [ "\$TYPE" != "mesh" ]; then
        log "Setting mesh mode"
        ip link set wlan1 down 2>/dev/null || true
        sleep 1
        iw dev wlan1 set type mp 2>/dev/null || true
        ip link set wlan1 up 2>/dev/null || true
        sleep 2
        iw dev wlan1 mesh join birddog-mesh 2>/dev/null || true
        log "Mesh join issued"
    fi

    IP=\$(ip -4 addr show wlan1 | grep inet)

    if [ -z "\$IP" ]; then
        ip addr add \$MESH_IP/24 dev wlan1 2>/dev/null || true
        log "Mesh IP restored"
    fi

    sleep 3

done
EOF

chmod +x /usr/local/bin/birddog-meshd.sh


echo "Installing systemd mesh daemon..."

cat <<EOF > /etc/systemd/system/birddog-mesh.service
[Unit]
Description=BirdDog Mesh Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/birddog-meshd.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-mesh
systemctl start birddog-mesh


echo ""
echo "====================================="
echo "Mesh watchdog installed"
echo "Node: $HOSTNAME_INPUT"
echo "Mesh IP: $MESH_IP"
echo "====================================="
echo ""
echo "Check runtime:"
echo "tail -f /opt/birddog/mesh/mesh_runtime.log"
echo ""
