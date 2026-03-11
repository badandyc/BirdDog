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

MESH_IP="10.10.20.$((NODE_NUM))"

echo "Node: $HOSTNAME_INPUT"
echo "Mesh IP: $MESH_IP"


LOG_DIR="/opt/birddog/mesh"
mkdir -p "$LOG_DIR"

RUNTIME_LOG="$LOG_DIR/mesh_runtime.log"

echo "Stopping dhcpcd if present..."
systemctl stop dhcpcd.service 2>/dev/null || true
systemctl disable dhcpcd.service 2>/dev/null || true


echo "Installing mesh runtime daemon..."

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

echo "Interface detected" >> \$LOG

ip link set wlan1 down >> \$LOG 2>&1 || true
iw dev wlan1 set type mp >> \$LOG 2>&1
ip link set wlan1 up >> \$LOG 2>&1

iw dev wlan1 set power_save off >> \$LOG 2>&1 || true

sleep 2

iw dev wlan1 mesh join birddog-mesh >> \$LOG 2>&1 || true

ip addr flush dev wlan1 >> \$LOG 2>&1 || true
ip addr add $MESH_IP/24 dev wlan1 >> \$LOG 2>&1

echo "Interface state:" >> \$LOG
ip addr show wlan1 >> \$LOG

echo "Starting convergence daemon..." >> \$LOG

CONVERGED=0

while [ "\$CONVERGED" -eq 0 ]
do
    for ip in \$(seq 1 50)
    do
        TARGET="10.10.20.\$ip"

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
    for ip in \$(seq 1 50)
    do
        ping -c1 -W1 10.10.20.\$ip >/dev/null 2>&1
    done
    sleep 30
done
) &

echo "Mesh runtime complete" >> \$LOG
EOF

chmod +x /usr/local/bin/birddog-mesh-join.sh


echo "Installing systemd mesh service..."

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


echo "Installing mesh CLI..."

cat <<'EOF' > /usr/local/bin/mesh
#!/bin/bash

resolve_peer() {

MAC=$1

IP=$(ip neigh | grep $MAC | awk '{print $1}' | head -n1)

if [ -n "$IP" ]; then
    HOST=$(avahi-resolve-address $IP 2>/dev/null | awk '{print $2}' | sed 's/.local//')
    if [ -n "$HOST" ]; then
        echo $HOST
        return
    fi
fi

echo $MAC

}

mesh_table() {

echo ""
echo "Node        IP              Signal      Rate       Metric"
echo "--------------------------------------------------------------"

SELF_NODE=$(hostname)
SELF_IP=$(ip -4 addr show wlan1 | grep inet | awk '{print $2}' | cut -d/ -f1)

printf "%-12s %-15s %-10s %-10s %-10s\n" "$SELF_NODE" "$SELF_IP" "self" "-" "-"

iw dev wlan1 station dump | grep Station | awk '{print $2}' | while read MAC
do

HOST=$(resolve_peer $MAC)
IP=$(ip neigh | grep $MAC | awk '{print $1}' | head -n1)

SIGNAL=$(iw dev wlan1 station dump | grep -A20 $MAC | grep signal: | awk '{print $2}' | head -n1)
RATE=$(iw dev wlan1 station dump | grep -A20 $MAC | grep bitrate | awk '{print $3}' | head -n1)
METRIC=$(iw dev wlan1 station dump | grep -A20 $MAC | grep metric | awk '{print $4}' | head -n1)

printf "%-12s %-15s %-10s %-10s %-10s\n" "$HOST" "$IP" "$SIGNAL dBm" "$RATE" "$METRIC"

done

echo ""

}

case "$1" in

status)

echo "================================="
echo "BirdDog Mesh Status"
echo "Node: $(hostname)"
echo "Time: $(date)"
echo "================================="

TYPE=$(iw dev wlan1 info 2>/dev/null | grep type | awk '{print $2}')
IP=$(ip -4 addr show wlan1 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
PEERS=$(iw dev wlan1 station dump | grep Station | wc -l)

echo "Interface Type : $TYPE"
echo "Mesh IP        : $IP"
echo "Peers          : $PEERS"

mesh_table
;;

peers)

echo "================================="
echo "BirdDog Mesh Peer Details"
echo "================================="

iw dev wlan1 station dump | grep Station | awk '{print $2}' | while read MAC
do

HOST=$(resolve_peer $MAC)

SIGNAL=$(iw dev wlan1 station dump | grep -A20 $MAC | grep signal: | awk '{print $2}' | head -n1)
RATE=$(iw dev wlan1 station dump | grep -A20 $MAC | grep bitrate | awk '{print $3}' | head -n1)
METRIC=$(iw dev wlan1 station dump | grep -A20 $MAC | grep metric | awk '{print $4}' | head -n1)

echo ""
echo "Peer: $HOST"
echo "MAC: $MAC"
echo "Signal: $SIGNAL dBm"
echo "TX Rate: $RATE"
echo "Link Metric: $METRIC"

done

echo ""
;;

""|help)

echo ""
echo "================================="
echo "BirdDog Mesh Command"
echo "================================="
echo ""
echo "mesh status   → mesh health overview"
echo "mesh peers    → RF metrics"
echo "mesh help     → this menu"
echo ""
echo "================================="
echo ""
;;

*)

echo "Unknown command"
;;

esac
EOF

chmod +x /usr/local/bin/mesh


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
