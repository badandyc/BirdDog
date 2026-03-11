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

STATE="INIT"
LAST_PEER_TIME=$(date +%s)
LAST_JOIN_TIME=0

JOIN_COOLDOWN=15
SUSPECT_THRESHOLD=15
RECOVERY_THRESHOLD=40

log() {
echo "[mesh] $1" >> $LOG
}

log_state() {
log "STATE → $1"
}

interface_exists() {
ip link show wlan1 >/dev/null 2>&1
}

mesh_joined() {
iw dev wlan1 info 2>/dev/null | grep -q "mesh id birddog-mesh"
}

assign_ip_if_missing() {
if ! ip addr show wlan1 | grep -q "$MESH_IP"; then
ip addr replace $MESH_IP dev wlan1 >> $LOG 2>&1 || true
log "mesh IP restored"
fi
}

normalize_and_join() {

```
NOW=\$(date +%s)
if (( NOW - LAST_JOIN_TIME < JOIN_COOLDOWN )); then
    log "join cooldown active"
    return
fi

log "normalization + join attempt"

ip link set wlan1 down >> \$LOG 2>&1 || true
iw dev wlan1 set type mp >> \$LOG 2>&1 || return
iw dev wlan1 set power_save off >> \$LOG 2>&1 || true

ip link set wlan1 up >> \$LOG 2>&1 || true
iw dev wlan1 set channel 1 HT20 >> \$LOG 2>&1 || true

sleep 1

iw dev wlan1 mesh join birddog-mesh freq 2412 >> \$LOG 2>&1 || {
    log "join failed"
    sleep \$((RANDOM % 4 + 2))
    return
}

ip addr replace \$MESH_IP dev wlan1 >> \$LOG 2>&1 || true

LAST_JOIN_TIME=\$(date +%s)

log "join successful"
```

}

log "================================="
log "Mesh runtime start $(date)"
log "Hostname: $(hostname)"

sleep 5

STATE="WAIT_INTERFACE"
log_state "$STATE"

while true
do

```
# ---------- WAIT_INTERFACE ----------
if ! interface_exists; then
    if [[ "\$STATE" != "WAIT_INTERFACE" ]]; then
        STATE="WAIT_INTERFACE"
        log_state "\$STATE"
    fi
    sleep 2
    continue
fi

# ---------- FIRST NORMALIZE ----------
if [[ "\$STATE" == "WAIT_INTERFACE" ]]; then
    STATE="NORMALIZE"
    log_state "\$STATE"
    normalize_and_join
    STATE="CONVERGING"
    log_state "\$STATE"
fi

# ---------- HARD CORRECTNESS CHECK ----------
if ! mesh_joined; then
    log "mesh membership lost"
    STATE="RECOVERY"
    log_state "\$STATE"
fi

assign_ip_if_missing

# ---------- PEER DETECTION ----------
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

NOW=\$(date +%s)
DELTA=\$((NOW - LAST_PEER_TIME))

# ---------- STATE MACHINE ----------
if [[ "\$STATE" == "CONVERGING" ]]; then

    if [[ "\$PEER_FOUND" -eq 1 ]]; then
        STATE="STEADY"
        log_state "\$STATE"
    fi

elif [[ "\$STATE" == "STEADY" ]]; then

    if (( DELTA > SUSPECT_THRESHOLD )); then
        STATE="SUSPECT"
        log_state "\$STATE"
    fi

elif [[ "\$STATE" == "SUSPECT" ]]; then

    if [[ "\$PEER_FOUND" -eq 1 ]]; then
        STATE="STEADY"
        log_state "\$STATE"

    elif (( DELTA > RECOVERY_THRESHOLD )); then
        STATE="RECOVERY"
        log_state "\$STATE"
    fi

elif [[ "\$STATE" == "RECOVERY" ]]; then

    normalize_and_join
    STATE="CONVERGING"
    log_state "\$STATE"
fi

# ---------- BEHAVIOR ----------
if [[ "\$STATE" == "CONVERGING" ]]; then
    sleep 2
    continue
fi

if [[ "\$STATE" == "SUSPECT" ]]; then
    sleep 5
    continue
fi

# STEADY warmer
for peer in \$(ip neigh show dev wlan1 | awk '{print \$1}')
do
    ping -c1 -W1 \$peer >/dev/null 2>&1
done

sleep \$((30 + RANDOM % 5))
```

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
echo "birddog mesh status"
echo ""
