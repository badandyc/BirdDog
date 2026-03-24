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

# GPIO pin for role switch (BCM numbering)
# open (high) = BDM, closed (low) = BDC
GPIO_SWITCH=5

# -------------------------------------------------------
# Phase 0 — Existing configuration check
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 0 — Existing Configuration Check"
echo "-------------------------------------"

CURRENT_HOST=$(hostname)
MESH_CONF="$BIRDDOG_ROOT/mesh/mesh.conf"

if [[ "$CURRENT_HOST" =~ ^bd[cm]-[0-9]{2}$ && -f "$MESH_CONF" ]]; then

    source "$MESH_CONF"
    CURRENT_ROLE=$(echo "$CURRENT_HOST" | cut -d- -f1)
    CURRENT_NODE=$(echo "$CURRENT_HOST" | cut -d- -f2)

    echo ""
    echo "  Existing configuration detected:"
    echo "    Hostname : $CURRENT_HOST"
    echo "    Role     : $CURRENT_ROLE"
    echo "    Mesh IP  : $MESH_IP"
    echo ""
    echo "  [K]eep current configuration"
    echo "  [R]econfigure"
    echo "  [N]o / abort"
    echo ""
    read -r -p "  Choice: " KEEP_CHOICE

    if [[ "$KEEP_CHOICE" == "K" ]]; then
        echo ""
        echo "  Keeping existing configuration — no changes made."
        echo ""
        echo "====================================="
        echo "Device configuration complete"
        echo "  Hostname : $CURRENT_HOST"
        echo "  Role     : $CURRENT_ROLE"
        echo "  Mesh IP  : $MESH_IP"
        echo "====================================="
        exit 0
    elif [[ "$KEEP_CHOICE" == "N" ]]; then
        echo "  Aborted."
        exit 0
    elif [[ "$KEEP_CHOICE" == "R" ]]; then
        echo "  Proceeding with reconfiguration..."
    else
        echo "  Invalid selection — aborted."
        exit 1
    fi

else
    echo "  No existing configuration detected — proceeding with fresh configure"
fi

# -------------------------------------------------------
# Phase 1 — Role detection via hardware switch
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 1 — Role Detection"
echo "-------------------------------------"

# Read GPIO 5 using sysfs — no Python dependency needed here
# Export pin if not already exported, suppress all errors cleanly
if [[ ! -d /sys/class/gpio/gpio${GPIO_SWITCH} ]]; then
    echo "${GPIO_SWITCH}" > /sys/class/gpio/export 2>/dev/null || true
    sleep 0.2
fi

# Set direction only if the file exists — avoids noise on kernels
# that auto-configure the pin direction
if [[ -f /sys/class/gpio/gpio${GPIO_SWITCH}/direction ]]; then
    echo "in" > /sys/class/gpio/gpio${GPIO_SWITCH}/direction 2>/dev/null || true
fi

GPIO_VAL=$(cat /sys/class/gpio/gpio${GPIO_SWITCH}/value 2>/dev/null || echo "1")

if [[ "$GPIO_VAL" == "1" ]]; then
    ROLE="bdm"
    echo "  Switch position : OPEN → BDM"
else
    ROLE="bdc"
    echo "  Switch position : CLOSED → BDC"
fi

# -------------------------------------------------------
# Phase 2 — Auto node assignment
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 2 — Node Assignment"
echo "-------------------------------------"

echo "  Scanning mesh for existing $ROLE nodes..."

AUTO_NODE=""

if [[ "$ROLE" == "bdm" ]]; then
    # BDM: scan 10.10.20.1 through 10.10.20.9
    for slot in $(seq 1 9); do
        TARGET="10.10.20.$slot"
        if ! ping -c1 -W1 "$TARGET" >/dev/null 2>&1; then
            AUTO_NODE=$(printf "%02d" $slot)
            echo "  Slot $slot ($TARGET) available — assigning bdm-${AUTO_NODE}"
            break
        else
            echo "  Slot $slot ($TARGET) in use"
        fi
    done
else
    # BDC: scan 10.10.20.10, .20 ... .230
    for slot in $(seq 1 23); do
        TARGET="10.10.20.$((slot * 10))"
        if ! ping -c1 -W1 "$TARGET" >/dev/null 2>&1; then
            AUTO_NODE=$(printf "%02d" $slot)
            echo "  Slot $slot ($TARGET) available — assigning bdc-${AUTO_NODE}"
            break
        else
            echo "  Slot $slot ($TARGET) in use"
        fi
    done
fi

if [[ -z "$AUTO_NODE" ]]; then
    echo ""
    echo "  WARNING: No available slots found — all nodes may be in use"
    echo "  Defaulting to slot 01 — verify manually"
    AUTO_NODE="01"
fi

AUTO_HOSTNAME="${ROLE}-${AUTO_NODE}"

if [[ "$ROLE" == "bdm" ]]; then
    AUTO_MESH_IP="10.10.20.$((10#$AUTO_NODE))"
else
    AUTO_MESH_IP="10.10.20.$((10#$AUTO_NODE * 10))"
fi

AUTO_STREAM="cam${AUTO_NODE}"

# -------------------------------------------------------
# Phase 3 — Operator confirmation
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 3 — Confirm Configuration"
echo "-------------------------------------"
AUTO_ROLE="$ROLE"

echo ""
echo "  Proposed configuration:"
echo "    Hostname : $AUTO_HOSTNAME"
echo "    Role     : $ROLE"
echo "    Mesh IP  : $AUTO_MESH_IP"
if [[ "$ROLE" == "bdc" ]]; then
    echo "    Stream   : $AUTO_STREAM"
fi
echo ""

echo "  [Y]es  accept proposed configuration"
echo "  [N]o   abort"
echo "  [OVERRIDE]  manually enter full hostname (any role — switch mismatch will trigger SOS on reboot)"
echo ""
read -r -p "  Choice: " CONFIRM

if [[ "$CONFIRM" == "Y" ]]; then
    HOSTNAME_INPUT="$AUTO_HOSTNAME"
    MESH_IP="$AUTO_MESH_IP"
    NODE_NUM="$AUTO_NODE"
    STREAM_NAME="$AUTO_STREAM"

elif [[ "$CONFIRM" == "OVERRIDE" ]]; then
    echo ""

    # Ask for role first
    while true; do
        read -r -p "  Enter role (BDM or BDC): " OVERRIDE_ROLE_INPUT
        OVERRIDE_ROLE_INPUT=$(echo "$OVERRIDE_ROLE_INPUT" | tr '[:upper:]' '[:lower:]')
        if [[ "$OVERRIDE_ROLE_INPUT" == "bdm" || "$OVERRIDE_ROLE_INPUT" == "bdc" ]]; then
            break
        fi
        echo "  Invalid — enter BDM or BDC"
    done

    ROLE="$OVERRIDE_ROLE_INPUT"

    # Re-scan mesh for the overridden role
    echo ""
    echo "  Scanning mesh for existing $ROLE nodes..."

    OVERRIDE_NODE=""
    if [[ "$ROLE" == "bdm" ]]; then
        for slot in $(seq 1 9); do
            TARGET="10.10.20.$slot"
            if ! ping -c1 -W1 "$TARGET" >/dev/null 2>&1; then
                OVERRIDE_NODE=$(printf "%02d" $slot)
                echo "  Slot $slot ($TARGET) available — assigning ${ROLE}-${OVERRIDE_NODE}"
                break
            else
                echo "  Slot $slot ($TARGET) in use"
            fi
        done
    else
        for slot in $(seq 1 23); do
            TARGET="10.10.20.$((slot * 10))"
            if ! ping -c1 -W1 "$TARGET" >/dev/null 2>&1; then
                OVERRIDE_NODE=$(printf "%02d" $slot)
                echo "  Slot $slot ($TARGET) available — assigning ${ROLE}-${OVERRIDE_NODE}"
                break
            else
                echo "  Slot $slot ($TARGET) in use"
            fi
        done
    fi

    if [[ -z "$OVERRIDE_NODE" ]]; then
        echo "  WARNING: No available slots found — defaulting to slot 01"
        OVERRIDE_NODE="01"
    fi

    HOSTNAME_INPUT="${ROLE}-${OVERRIDE_NODE}"
    NODE_NUM="$OVERRIDE_NODE"
    STREAM_NAME="cam${NODE_NUM}"

    if [[ "$ROLE" == "bdm" ]]; then
        MESH_IP="10.10.20.$((10#$NODE_NUM))"
    else
        MESH_IP="10.10.20.$((10#$NODE_NUM * 10))"
    fi

    echo ""
    echo "  Override configuration:"
    echo "    Hostname : $HOSTNAME_INPUT"
    echo "    Role     : $ROLE"
    echo "    Mesh IP  : $MESH_IP"
    if [[ "$ROLE" == "bdc" ]]; then
        echo "    Stream   : $STREAM_NAME"
    fi

    if [[ "$ROLE" != "$AUTO_ROLE" ]]; then
        echo ""
        echo "  WARNING: Committed role ($ROLE) differs from switch position ($AUTO_ROLE)"
        echo "  Node will boot to safe state with SOS alert until switch is flipped to match"
    fi

    echo ""
    read -r -p "  Accept override? (Y/N): " OVERRIDE_CONFIRM
    if [[ "$OVERRIDE_CONFIRM" != "Y" ]]; then
        echo "  Aborted."
        exit 0
    fi

elif [[ "$CONFIRM" == "N" ]]; then
    echo "  Aborted."
    exit 0
else
    echo "  Invalid selection — aborted."
    exit 1
fi

echo ""
echo "  Hostname : $HOSTNAME_INPUT"
echo "  Role     : $ROLE"
echo "  Node     : $NODE_NUM"
echo "  Mesh IP  : $MESH_IP"
if [[ "$ROLE" == "bdc" ]]; then
    echo "  Stream   : $STREAM_NAME"
fi

# -------------------------------------------------------
# Phase 4 — Hostname + hosts table
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 4 — Hostname + Host Table"
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
# Phase 5 — Role installer
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 5 — Role: $ROLE"
echo "-------------------------------------"

if [[ "$ROLE" == "bdc" ]]; then

    # Scan mesh for existing BDM nodes and auto-suggest the first one found
    echo "  Scanning mesh for BDM nodes..."
    AUTO_BDM=""
    for slot in $(seq 1 9); do
        TARGET="10.10.20.$slot"
        if ping -c1 -W1 "$TARGET" >/dev/null 2>&1; then
            AUTO_BDM="bdm-$(printf "%02d" $slot)"
            echo "  Found BDM at $TARGET → $AUTO_BDM"
            break
        fi
    done

    if [[ -n "$AUTO_BDM" ]]; then
        echo ""
        read -r -p "  BDM hostname [$AUTO_BDM]: " BDM_NAME
        if [[ -z "$BDM_NAME" ]]; then
            BDM_NAME="$AUTO_BDM"
        fi
    else
        echo "  No BDM found on mesh — enter manually"
        while true; do
            read -r -p "  Enter BDM hostname (bdm-##, without .local): " BDM_NAME
            [[ -z "$BDM_NAME" ]] && continue
            if [[ "$BDM_NAME" =~ ^bdm-[0-9]{2}$ ]]; then
                break
            fi
            echo "  Invalid format — must be bdm-01, bdm-02, etc."
        done
    fi

    if [[ ! "$BDM_NAME" =~ ^bdm-[0-9]{2}$ ]]; then
        echo "  Invalid format — must be bdm-01, bdm-02, etc."
        exit 1
    fi

    BDM_HOST="${BDM_NAME}.local"

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
# Phase 6 — Mesh
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 6 — Mesh"
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
