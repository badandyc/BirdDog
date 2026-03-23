#!/bin/bash
set -e
set -o pipefail

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -E bash /opt/birddog/common/device_configure.sh "$@"
fi

echo "====================================="
echo "BirdDog Device Configuration"
echo "====================================="

BIRDDOG_ROOT="/opt/birddog"
BDC_CONFIG="$BIRDDOG_ROOT/bdc/bdc.conf"
CURRENT_HOST=$(hostname)
REUSE_ALL=0

# -------------------------------------------------------
# Phase 1 — Existing configuration check
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 1 — Existing Configuration Check"
echo "-------------------------------------"

if [[ "$CURRENT_HOST" =~ ^bdc-[0-9]{2}$ && -f "$BDC_CONFIG" ]]; then

    source "$BDC_CONFIG"

    if [[ -n "$BDM_HOST" ]]; then
        echo ""
        echo "Existing BDC configuration detected:"
        echo "  BDC Hostname : $CURRENT_HOST"
        echo "  BDM Host     : $BDM_HOST"
        echo "  Stream Name  : $STREAM_NAME"
        echo ""

        read -r -p "Keep existing settings? (y/n): " KEEP_ALL

        if [[ "$KEEP_ALL" =~ ^[Yy]$ ]]; then
            HOSTNAME_INPUT="$CURRENT_HOST"
            REUSE_ALL=1
        fi
    fi

fi

# -------------------------------------------------------
# Phase 2 — Hostname selection
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 2 — Hostname"
echo "-------------------------------------"

if [[ "$REUSE_ALL" != "1" ]]; then

    while true; do
        read -r -p "Enter hostname (bdm-## or bdc-##): " HOSTNAME_INPUT
        [[ -z "$HOSTNAME_INPUT" ]] && continue
        if [[ "$HOSTNAME_INPUT" =~ ^bd[cm]-[0-9]{2}$ ]]; then
            break
        fi
        echo "  Invalid format — must be bdm-01, bdc-02, etc."
    done

fi

ROLE=$(echo "$HOSTNAME_INPUT" | cut -d- -f1)
NODE_NUM=$(echo "$HOSTNAME_INPUT" | cut -d- -f2)
STREAM_NAME="cam${NODE_NUM}"

# IP scheme:
#   BDM → 10.10.20.1 - 10.10.20.9   (node number as-is)
#   BDC → 10.10.20.10, .20, .30...   (node number × 10)
if [[ "$ROLE" == "bdm" ]]; then
    MESH_IP="10.10.20.$((10#$NODE_NUM))"
else
    MESH_IP="10.10.20.$((10#$NODE_NUM * 10))"
fi

echo ""
echo "  Hostname : $HOSTNAME_INPUT"
echo "  Role     : $ROLE"
echo "  Node     : $NODE_NUM"
echo "  Mesh IP  : $MESH_IP"
echo "  Stream   : $STREAM_NAME"

# -------------------------------------------------------
# Phase 3 — Hostname + hosts table
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 3 — Hostname + Host Table"
echo "-------------------------------------"

# Stop cloud-init from overwriting our hostname on next boot
if [[ -f /etc/cloud/cloud-init.disabled ]] || [[ ! -d /etc/cloud ]]; then
    true
elif [[ -f /etc/cloud/cloud.cfg ]]; then
    sed -i 's/^manage_etc_hosts:.*/manage_etc_hosts: false/' /etc/cloud/cloud.cfg || true
    touch /etc/cloud/cloud-init.disabled
fi

echo "$HOSTNAME_INPUT" > /etc/hostname

TMP_HOSTS=$(mktemp)

cat >> "$TMP_HOSTS" << EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME_INPUT

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

# BirdDog Mesh Nodes
# BDM nodes: .1-.9   BDC nodes: .10,.20,.30...
EOF

# BDM entries — node number as-is (.1 through .9)
for slot in $(seq 1 9); do
    IP="10.10.20.$slot"
    BDM_NAME="bdm-$(printf "%02d" $slot)"
    echo "$IP $BDM_NAME" >> "$TMP_HOSTS"
done

# BDC entries — node number × 10 (.10 through .250)
for slot in $(seq 1 25); do
    IP="10.10.20.$((slot * 10))"
    BDC_NAME="bdc-$(printf "%02d" $slot)"
    echo "$IP $BDC_NAME" >> "$TMP_HOSTS"
done

mv "$TMP_HOSTS" /etc/hosts
echo "  /etc/hosts written"

hostnamectl set-hostname "$HOSTNAME_INPUT"
echo "  hostname set: $HOSTNAME_INPUT"

rm -rf /var/lib/avahi-daemon/* 2>/dev/null || true
systemctl enable avahi-daemon 2>/dev/null || true
systemctl restart avahi-daemon
echo "  avahi restarted"

# -------------------------------------------------------
# Phase 4 — Role installer
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 4 — Role: $ROLE"
echo "-------------------------------------"

if [[ "$ROLE" == "bdc" ]]; then

    if [[ "$REUSE_ALL" == "1" ]]; then
        echo ""
        echo "  Reusing existing BDC configuration"
        echo "  BDM Host : $BDM_HOST"
    else
        while true; do
            read -r -p "  Enter BDM hostname (bdm-##, without .local): " BDM_NAME
            [[ -z "$BDM_NAME" ]] && continue
            if [[ "$BDM_NAME" =~ ^bdm-[0-9]{2}$ ]]; then
                break
            fi
            echo "  Invalid format — must be bdm-01, bdm-02, etc."
        done

        BDM_HOST="${BDM_NAME}.local"
    fi

    echo ""
    echo "  Running BDC installer..."
    bash "$BIRDDOG_ROOT/bdc/bdc_fresh_install_setup.sh" \
        "$HOSTNAME_INPUT" \
        "$BDM_HOST" \
        "$STREAM_NAME"

elif [[ "$ROLE" == "bdm" ]]; then

    echo ""
    echo "  Running BDM installer..."
    bash "$BIRDDOG_ROOT/bdm/bdm_AP_setup.sh"
    bash "$BIRDDOG_ROOT/bdm/bdm_mediamtx_setup.sh"
    bash "$BIRDDOG_ROOT/bdm/bdm_web_setup.sh"

else
    echo "ERROR: Unknown role '$ROLE'"
    exit 1
fi

# -------------------------------------------------------
# Phase 5 — Mesh
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 5 — Mesh"
echo "-------------------------------------"

# Write mesh.conf — runtime script reads this for the committed mesh IP
# This replaces the bootstrap temp IP with the node permanent IP
mkdir -p "$BIRDDOG_ROOT/mesh"

cat > "$BIRDDOG_ROOT/mesh/mesh.conf" << EOF
MESH_IP="${MESH_IP}/24"
EOF

echo "  mesh.conf written — IP: $MESH_IP/24"

# Restart mesh service so it picks up the committed IP immediately
systemctl restart birddog-mesh.service

echo "  Waiting for mesh service to start..."
sleep 5

if systemctl is-active --quiet birddog-mesh.service; then
    echo "  birddog-mesh : running"
else
    echo ""
    echo "  WARNING: birddog-mesh service did not start"
    echo "  This may be expected before first reboot"
fi

# -------------------------------------------------------
# Done
# -------------------------------------------------------

echo ""
echo "====================================="
echo "Device configuration complete"
echo "  Hostname : $HOSTNAME_INPUT"
echo "  Role     : $ROLE"
echo "  Mesh IP  : $MESH_IP"
if [[ "$ROLE" == "bdc" ]]; then
    echo "  Stream   : rtsp://$BDM_HOST:8554/$STREAM_NAME"
fi
echo "====================================="
echo ""
echo "====================================="
echo "⚠  REBOOT REQUIRED"
echo "====================================="
echo ""
echo "  Configuration changes do not take full effect"
echo "  until the node is rebooted."
echo ""
echo "    sudo reboot"
echo ""
