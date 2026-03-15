#!/bin/bash
set -e

echo "====================================="
echo "BirdDog Mesh Network Setup"
echo "====================================="

HOSTNAME_INPUT="$1"

if [[ -z "$HOSTNAME_INPUT" ]]; then
    echo "ERROR: Hostname not provided"
    echo "Usage: add_mesh_network.sh <hostname>"
    exit 1
fi

NODE_NUM=$(echo "$HOSTNAME_INPUT" | grep -oE '[0-9]{2}')

if [[ -z "$NODE_NUM" ]]; then
    echo "ERROR: Could not extract node number from hostname: $HOSTNAME_INPUT"
    exit 1
fi

# IP scheme:
#   BDM → 10.10.20.1 - 10.10.20.9   (node number as-is)
#   BDC → 10.10.20.10, .20, .30...   (node number × 10)
if [[ "$HOSTNAME_INPUT" =~ ^bdm- ]]; then
    MESH_IP="10.10.20.$((10#$NODE_NUM))"
else
    MESH_IP="10.10.20.$((10#$NODE_NUM * 10))"
fi

echo "Node     : $HOSTNAME_INPUT"
echo "Mesh IP  : $MESH_IP/24"

LOG_DIR="/opt/birddog/mesh"
mkdir -p "$LOG_DIR"
RUNTIME_LOG="$LOG_DIR/mesh_runtime.log"

# Disable dhcpcd — we manage wlan1 addressing manually
systemctl stop dhcpcd.service 2>/dev/null || true
systemctl disable dhcpcd.service 2>/dev/null || true

# -------------------------------------------------------
# Write the mesh runtime script
# -------------------------------------------------------

cat > /usr/local/bin/birddog-mesh-join.sh << 'RUNTIME_EOF'
#!/bin/bash

# BirdDog Mesh Runtime
# Manages 802.11s mesh membership on wlan1.
# Runs as a systemd service (birddog-mesh.service).

LOG="__RUNTIME_LOG__"
MESH_IP="__MESH_IP__/24"

# State machine states:
#   WAIT_INTERFACE  wlan1 not yet visible
#   NORMALIZE       first join attempt in progress
#   CONVERGING      joined, waiting for first peer
#   STEADY          peer seen recently
#   SUSPECT         no peer for SUSPECT_THRESHOLD seconds
#   RECOVERY        no peer for RECOVERY_THRESHOLD seconds — rejoin

STATE="INIT"
LAST_PEER_TIME=0
LAST_JOIN_TIME=0

JOIN_COOLDOWN=15
SUSPECT_THRESHOLD=15
RECOVERY_THRESHOLD=40

log() {
    echo "[$(date '+%H:%M:%S')] [mesh] $1" >> "$LOG"
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
    if ! ip addr show wlan1 2>/dev/null | grep -q "$MESH_IP"; then
        ip addr replace "$MESH_IP" dev wlan1 >> "$LOG" 2>&1 || true
        log "mesh IP restored: $MESH_IP"
    fi
}

normalize_and_join() {

    local NOW
    NOW=$(date +%s)

    if (( NOW - LAST_JOIN_TIME < JOIN_COOLDOWN )); then
        log "join cooldown active — skipping"
        return
    fi

    log "normalize + join attempt"

    ip link set wlan1 down >> "$LOG" 2>&1 || true
    sleep 1

    iw dev wlan1 set type mp >> "$LOG" 2>&1 || {
        log "ERROR: could not set wlan1 to mesh point mode"
        return 1
    }

    iw dev wlan1 set power_save off >> "$LOG" 2>&1 || true
    ip link set wlan1 up >> "$LOG" 2>&1 || true
    sleep 1

    iw dev wlan1 set channel 1 HT20 >> "$LOG" 2>&1 || true

    iw dev wlan1 mesh join birddog-mesh freq 2412 HT20 >> "$LOG" 2>&1 || {
        log "mesh join failed — will retry"
        sleep $(( RANDOM % 4 + 2 ))
        LAST_JOIN_TIME=$(date +%s)
        return 1
    }

    ip addr replace "$MESH_IP" dev wlan1 >> "$LOG" 2>&1 || true

    LAST_JOIN_TIME=$(date +%s)
    log "join successful — IP: $MESH_IP"
}

check_for_peer() {
    local PEER_FOUND=0

    if ip neigh show dev wlan1 2>/dev/null | grep -qv "FAILED"; then
        PEER_FOUND=1
    else
        local OWN_OCTET
        OWN_OCTET=$(echo "$MESH_IP" | cut -d/ -f1 | awk -F. '{print $4}')
        local OWN_NUM=$(( OWN_OCTET / 10 ))

        for delta in -1 1 -2 2 -3 3; do
            local SLOT=$(( OWN_NUM + delta ))
            [[ "$SLOT" -lt 1 || "$SLOT" -gt 25 ]] && continue
            local TARGET="10.10.20.$((SLOT * 10))"
            ping -c1 -W1 "$TARGET" >/dev/null 2>&1 || true
            if ip neigh show dev wlan1 2>/dev/null | grep -q "$TARGET"; then
                PEER_FOUND=1
                break
            fi
        done
    fi

    echo "$PEER_FOUND"
}

# -------------------------------------------------------
# Main loop
# -------------------------------------------------------

log "================================="
log "Mesh runtime start"
log "Hostname : $(hostname)"
log "Mesh IP  : $MESH_IP"

sleep 5

STATE="WAIT_INTERFACE"
log_state "$STATE"

while true; do

    # ---------- WAIT_INTERFACE ----------
    if ! interface_exists; then
        if [[ "$STATE" != "WAIT_INTERFACE" ]]; then
            STATE="WAIT_INTERFACE"
            log_state "$STATE"
        fi
        sleep 2
        continue
    fi

    # ---------- FIRST JOIN ----------
    if [[ "$STATE" == "WAIT_INTERFACE" ]]; then
        STATE="NORMALIZE"
        log_state "$STATE"
        normalize_and_join || true
        STATE="CONVERGING"
        log_state "$STATE"
    fi

    # ---------- HARD CORRECTNESS CHECK ----------
    if ! mesh_joined; then
        log "mesh membership lost"
        STATE="RECOVERY"
        log_state "$STATE"
    fi

    assign_ip_if_missing

    # ---------- PEER DETECTION ----------
    PEER_FOUND=$(check_for_peer)

    NOW=$(date +%s)

    if [[ "$PEER_FOUND" -eq 1 && "$LAST_PEER_TIME" -eq 0 ]]; then
        LAST_PEER_TIME=$NOW
    fi

    DELTA=0
    [[ "$LAST_PEER_TIME" -gt 0 ]] && DELTA=$(( NOW - LAST_PEER_TIME ))

    if [[ "$PEER_FOUND" -eq 1 ]]; then
        LAST_PEER_TIME=$NOW
    fi

    # ---------- STATE MACHINE ----------
    case "$STATE" in

        CONVERGING)
            if [[ "$PEER_FOUND" -eq 1 ]]; then
                STATE="STEADY"
                log_state "$STATE"
            fi
            ;;

        STEADY)
            if (( DELTA > SUSPECT_THRESHOLD )); then
                STATE="SUSPECT"
                log_state "$STATE"
            fi
            ;;

        SUSPECT)
            if [[ "$PEER_FOUND" -eq 1 ]]; then
                STATE="STEADY"
                log_state "$STATE"
            elif (( DELTA > RECOVERY_THRESHOLD )); then
                STATE="RECOVERY"
                log_state "$STATE"
            fi
            ;;

        RECOVERY)
            normalize_and_join || true
            STATE="CONVERGING"
            log_state "$STATE"
            ;;

    esac

    # ---------- SLEEP BY STATE ----------
    case "$STATE" in
        CONVERGING) sleep 2  ;;
        SUSPECT)    sleep 5  ;;
        STEADY)
            while IFS= read -r line; do
                PEER_IP=$(echo "$line" | awk '{print $1}')
                [[ -n "$PEER_IP" ]] && ping -c1 -W1 "$PEER_IP" >/dev/null 2>&1 || true
            done < <(ip neigh show dev wlan1 2>/dev/null | grep -v FAILED)
            sleep $(( 30 + RANDOM % 5 ))
            ;;
        *)          sleep 5  ;;
    esac

done
RUNTIME_EOF

# Inject node-specific values
sed -i "s|__RUNTIME_LOG__|${RUNTIME_LOG}|g" /usr/local/bin/birddog-mesh-join.sh
sed -i "s|__MESH_IP__|${MESH_IP}|g"         /usr/local/bin/birddog-mesh-join.sh

chmod +x /usr/local/bin/birddog-mesh-join.sh

# -------------------------------------------------------
# Install systemd service
# -------------------------------------------------------

cat > /etc/systemd/system/birddog-mesh.service << EOF
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
echo "  Node    : $HOSTNAME_INPUT"
echo "  Mesh IP : $MESH_IP/24"
echo "====================================="
echo ""
echo "Monitor mesh with:"
echo "  birddog verify"
echo "  tail -f $RUNTIME_LOG"
echo ""
