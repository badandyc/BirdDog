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
MESH_IP="$MESH_IP/24"

echo "=================================" >> \$LOG
echo "Mesh runtime start \$(date)" >> \$LOG
echo "Hostname: \$(hostname)" >> \$LOG

sleep 5

LAST_PEER_TIME=\$(date +%s)

normalize_and_join() {

    echo "[mesh] normalization + join attempt" >> \$LOG

    ip link set wlan1 down >> \$LOG 2>&1 || true
    iw dev wlan1 set type mp >> \$LOG 2>&1 || return
    iw dev wlan1 set power_save off >> \$LOG 2>&1 || true

    ip link set wlan1 up >> \$LOG 2>&1 || true
    iw dev wlan1 set channel 1 HT20 >> \$LOG 2>&1 || true

    sleep 1

    iw dev wlan1 mesh join birddog-mesh freq 2412 >> \$LOG 2>&1 || {
        echo "[mesh] join failed" >> \$LOG
        sleep \$((RANDOM % 4 + 2))
        return
    }

    ip addr replace \$MESH_IP dev wlan1 >> \$LOG 2>&1 || true

    echo "[mesh] join successful" >> \$LOG
}

while true
do

    # --- interface disappearance trigger ---
    if ! ip link show wlan1 >/dev/null 2>&1; then
        echo "[mesh] wlan1 missing" >> \$LOG
        sleep 2
        continue
    fi

    # --- peer detection ---
    PEER_FOUND=0

    for slot in \$(seq 1 25)
    do
        TARGET="10.10.20.\$((slot*10))"
        ping -c1 -W1 \$TARGET >/dev/null 2>&1

        if ip neigh show dev wlan1 | grep -q "\$TARGET"; then
            PEER_FOUND=1
            LAST_PEER_TIME=\$(date +%s)
            break
        fi
    done

    # --- peer floor watchdog (20s) ---
    NOW=\$(date +%s)
    DELTA=\$((NOW - LAST_PEER_TIME))

    if [ "\$PEER_FOUND" -eq 0 ] && [ "\$DELTA" -gt 20 ]; then
        echo "[mesh] peer floor lost — rejoin required" >> \$LOG
        normalize_and_join
        sleep 3
        continue
    fi

    # --- steady warmer ---
    for slot in \$(seq 1 25)
    do
        ping -c1 -W1 10.10.20.\$((slot*10)) >/dev/null 2>&1
    done

    sleep 30

done
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
