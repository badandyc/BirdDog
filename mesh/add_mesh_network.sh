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

NODE_NUM=$(echo "$HOSTNAME_INPUT" | grep -oE '[0-9]{2}')

if [[ -z "$NODE_NUM" ]]; then
    echo "Hostname must end in number"
    exit 1
fi

MESH_IP="10.10.20.$((NODE_NUM*10))"

echo "Node: $HOSTNAME_INPUT"
echo "Mesh IP: $MESH_IP"

LOG_DIR="/opt/birddog/mesh"
mkdir -p "$LOG_DIR"
RUNTIME_LOG="$LOG_DIR/mesh_runtime.log"

systemctl stop dhcpcd.service 2>/dev/null || true
systemctl disable dhcpcd.service 2>/dev/null || true

cat <<EOF > /usr/local/bin/birddog-mesh-join.sh
#!/bin/bash

LOG="$RUNTIME_LOG"

echo "=================================" >> \$LOG
echo "Mesh runtime start \$(date)" >> \$LOG
echo "Hostname: \$(hostname)" >> \$LOG

sleep 5

until ip link show wlan1 >/dev/null 2>&1
do
    sleep 1
done

ip link set wlan1 down >> \$LOG 2>&1 || true
iw dev wlan1 set type mp >> \$LOG 2>&1
ip link set wlan1 up >> \$LOG 2>&1

iw dev wlan1 set power_save off >> \$LOG 2>&1 || true

sleep 2

iw dev wlan1 mesh join birddog-mesh >> \$LOG 2>&1 || true

ip addr flush dev wlan1 >> \$LOG 2>&1 || true
ip addr add $MESH_IP/24 dev wlan1 >> \$LOG 2>&1

echo "Starting convergence daemon..." >> \$LOG

CONVERGED=0

while [ "\$CONVERGED" -eq 0 ]
do
    for slot in \$(seq 1 25)
    do
        TARGET="10.10.20.\$((slot*10))"

        ping -c1 -W1 \$TARGET >/dev/null 2>&1

        if ip neigh show dev wlan1 | grep -q "\$TARGET"; then
            echo "Mesh convergence achieved with \$TARGET" >> \$LOG
            CONVERGED=1
            break
        fi
    done

    sleep 2
done

echo "Switching to steady warmer..." >> \$LOG

(
while true
do
    for slot in \$(seq 1 25)
    do
        ping -c1 -W1 10.10.20.\$((slot*10)) >/dev/null 2>&1
    done
    sleep 30
done
) &

echo "Mesh runtime complete" >> \$LOG
EOF

chmod +x /usr/local/bin/birddog-mesh-join.sh

cat <<EOF > /etc/systemd/system/birddog-mesh.service
[Unit]
Description=BirdDog Mesh Runtime
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/birddog-mesh-join.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-mesh.service
systemctl restart birddog-mesh.service

echo ""
echo "====================================="
echo "Mesh subsystem installed"
echo "Node: $HOSTNAME_INPUT"
echo "IP: $MESH_IP"
echo "====================================="
echo ""
echo "Verify mesh with:"
echo "mesh status"
echo ""
