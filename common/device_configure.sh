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

echo ""
echo "  Hostname : $HOSTNAME_INPUT"
echo "  Role     : $ROLE"
echo "  Node     : $NODE_NUM"
echo "  Stream   : $STREAM_NAME"

# -------------------------------------------------------
# Phase 3 — Hostname + hosts table
# Device configure owns ALL hostname setup.
# Write everything before restarting any services.
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 3 — Hostname + Host Table"
echo "-------------------------------------"

# Stop cloud-init from overwriting our hostname on next boot
if [[ -f /etc/cloud/cloud-init.disabled ]] || [[ ! -d /etc/cloud ]]; then
    true  # already disabled or not present
elif [[ -f /etc/cloud/cloud.cfg ]]; then
    sed -i 's/^manage_etc_hosts:.*/manage_etc_hosts: false/' /etc/cloud/cloud.cfg || true
    touch /etc/cloud/cloud-init.disabled
fi

# Write hostname to disk first — before hostnamectl, before avahi
echo "$HOSTNAME_INPUT" > /etc/hostname

# Build /etc/hosts
# Mesh IP scheme: node number × 10 → last octet
# e.g. node 01 → 10.10.20.10, node 02 → 10.10.20.20
# BDM and BDC with the same number share the same mesh IP by design —
# the fleet never has a BDM and BDC with the same node number.

TMP_HOSTS=$(mktemp)

cat >> "$TMP_HOSTS" << EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME_INPUT

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

# BirdDog Mesh Nodes
EOF

for slot in $(seq 1 25); do
    IP="10.10.20.$((slot * 10))"
    BDC_NAME="bdc-$(printf "%02d" $slot)"
    BDM_NAME="bdm-$(printf "%02d" $slot)"
    echo "$IP $BDC_NAME $BDM_NAME" >> "$TMP_HOSTS"
done

mv "$TMP_HOSTS" /etc/hosts
echo "  /etc/hosts written"

# Now apply hostname — /etc/hostname and /etc/hosts are already correct
hostnamectl set-hostname "$HOSTNAME_INPUT"
echo "  hostname set: $HOSTNAME_INPUT"

# Clear stale avahi cache and restart — hosts file is already in place
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

    # bdm_initial_setup no longer handles hostname — that's done above.
    # It handles AP networking, mediamtx, and the web dashboard.
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

bash "$BIRDDOG_ROOT/mesh/add_mesh_network.sh" "$HOSTNAME_INPUT"

echo "  Waiting for mesh service to start..."
sleep 5

if systemctl is-active --quiet birddog-mesh.service; then
    echo "  birddog-mesh : running"
else
    echo ""
    echo "  WARNING: birddog-mesh service did not start"
    echo "  This may be expected before first reboot"
    echo "  (radio mapping takes effect at next boot)"
fi

# -------------------------------------------------------
# Done
# -------------------------------------------------------

echo ""
echo "====================================="
echo "Device configuration complete"
echo "  Hostname : $HOSTNAME_INPUT"
echo "  Role     : $ROLE"
echo "  Mesh IP  : 10.10.20.$((10#$NODE_NUM * 10))"
if [[ "$ROLE" == "bdc" ]]; then
    echo "  Stream   : rtsp://$BDM_HOST:8554/$STREAM_NAME"
fi
echo "====================================="
echo ""
echo "Reboot now to apply radio mapping:"
echo "  sudo reboot"
echo ""
