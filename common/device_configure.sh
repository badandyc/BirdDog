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

SKIP_TO_INSTALLER=0

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
    echo "  [K]eep — re-run role installer with current settings"
    echo "  [R]econfigure — full reconfiguration from scratch"
    echo "  [N]o — abort"
    echo ""

    while true; do
        read -r -p "  Choice: " KEEP_CHOICE
        [[ "$KEEP_CHOICE" == "K" || "$KEEP_CHOICE" == "R" || "$KEEP_CHOICE" == "N" ]] && break
        echo "  Invalid — enter K, R, or N"
    done

    if [[ "$KEEP_CHOICE" == "K" ]]; then
        echo ""
        echo "  Keeping existing configuration — re-running role installer..."
        # Load existing values so Phase 5 onwards works correctly
        HOSTNAME_INPUT="$CURRENT_HOST"
        ROLE="$CURRENT_ROLE"
        NODE_NUM="$CURRENT_NODE"
        STREAM_NAME="cam${NODE_NUM}"
        MESH_IP=$(echo "$MESH_IP" | cut -d/ -f1)
        if [[ -f "$BDC_CONFIG" ]]; then
            source "$BDC_CONFIG"
        fi
        SKIP_TO_INSTALLER=1
    elif [[ "$KEEP_CHOICE" == "N" ]]; then
        echo "  Aborted."
        exit 0
    else
        echo "  Proceeding with reconfiguration..."
    fi

else
    echo "  No existing configuration detected — proceeding with fresh configure"
fi

if [[ "$SKIP_TO_INSTALLER" -eq 0 ]]; then

# -------------------------------------------------------
# Phase 1 — Role detection via hardware switch
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 1 — Role Detection"
echo "-------------------------------------"

if [[ ! -d /sys/class/gpio/gpio${GPIO_SWITCH} ]]; then
    echo "${GPIO_SWITCH}" > /sys/class/gpio/export 2>/dev/null || true
    sleep 0.2
fi

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

while true; do
    read -r -p "  Choice: " CONFIRM
    [[ "$CONFIRM" == "Y" || "$CONFIRM" == "N" || "$CONFIRM" == "OVERRIDE" ]] && break
    echo "  Invalid — enter Y, N, or OVERRIDE"
done

if [[ "$CONFIRM" == "Y" ]]; then
    HOSTNAME_INPUT="$AUTO_HOSTNAME"
    MESH_IP="$AUTO_MESH_IP"
    NODE_NUM="$AUTO_NODE"
    STREAM_NAME="$AUTO_STREAM"

elif [[ "$CONFIRM" == "OVERRIDE" ]]; then
    echo ""

    while true; do
        read -r -p "  Enter role (BDM or BDC): " OVERRIDE_ROLE_INPUT
        OVERRIDE_ROLE_INPUT=$(echo "$OVERRIDE_ROLE_INPUT" | tr '[:upper:]' '[:lower:]')
        if [[ "$OVERRIDE_ROLE_INPUT" == "bdm" || "$OVERRIDE_ROLE_INPUT" == "bdc" ]]; then
            break
        fi
        echo "  Invalid — enter BDM or BDC"
    done

    ROLE="$OVERRIDE_ROLE_INPUT"

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
    CONFIRMED_IN_OVERRIDE=1

elif [[ "$CONFIRM" == "N" ]]; then
    echo "  Aborted."
    exit 0
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

for slot in $(seq 1 9); do
    IP="10.10.20.$slot"
    BDM_NAME="bdm-$(printf "%02d" $slot)"
    echo "$IP $BDM_NAME" >> "$TMP_HOSTS"
done

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

fi  # end SKIP_TO_INSTALLER=0 block

# -------------------------------------------------------
# Phase 5 — Role installer
# -------------------------------------------------------

echo ""
echo "-------------------------------------"
echo "Phase 5 — Role: $ROLE"
echo "-------------------------------------"

if [[ "$ROLE" == "bdc" ]]; then

    if [[ "${CONFIRMED_IN_OVERRIDE:-0}" == "1" ]]; then
        echo "  BDC node confirmed in override — skipping"
        BDC_NAME_CONFIRM="Y"
    elif [[ "$SKIP_TO_INSTALLER" -eq 1 ]]; then
        echo "  BDC node confirmed from existing config — skipping"
        BDC_NAME_CONFIRM="Y"
    else
        echo ""
        echo "  Proposed BDC node:"
        echo "    Hostname : $HOSTNAME_INPUT"
        echo "    Mesh IP  : $MESH_IP"
        echo "    Stream   : $STREAM_NAME"
        echo ""
        read -r -p "  Accept BDC node name? [Y]es / [N]o: " BDC_NAME_CONFIRM
    fi

    if [[ "$BDC_NAME_CONFIRM" == "N" ]]; then
        echo ""
        while true; do
            read -r -p "  Enter node number (01-23): " OVERRIDE_NUM
            [[ -z "$OVERRIDE_NUM" ]] && continue
            if [[ "$OVERRIDE_NUM" =~ ^[0-9]{2}$ && "$((10#$OVERRIDE_NUM))" -ge 1 && "$((10#$OVERRIDE_NUM))" -le 23 ]]; then
                break
            fi
            echo "  Invalid — must be 01 through 23"
        done
        NODE_NUM="$OVERRIDE_NUM"
        HOSTNAME_INPUT="bdc-${NODE_NUM}"
        MESH_IP="10.10.20.$((10#$NODE_NUM * 10))"
        STREAM_NAME="cam${NODE_NUM}"
        echo ""
        echo "  Updated BDC node:"
        echo "    Hostname : $HOSTNAME_INPUT"
        echo "    Mesh IP  : $MESH_IP"
        echo "    Stream   : $STREAM_NAME"
    elif [[ "$BDC_NAME_CONFIRM" != "Y" ]]; then
        echo "  Aborted."
        exit 0
    fi

    echo ""
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
        read -r -p "  Use $AUTO_BDM as your BDM? [Y]es / [N]o: " BDM_CONFIRM
        if [[ "$BDM_CONFIRM" == "Y" ]]; then
            BDM_NAME="$AUTO_BDM"
        else
            echo ""
            while true; do
                read -r -p "  Enter BDM hostname (bdm-##, without .local): " BDM_NAME
                [[ -z "$BDM_NAME" ]] && continue
                if [[ "$BDM_NAME" =~ ^bdm-[0-9]{2}$ ]]; then
                    break
                fi
                echo "  Invalid format — must be bdm-01, bdm-02, etc."
            done
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
    BIRDDOG_CONFIGURE=1 bash "$BIRDDOG_ROOT/bdm/bdm_AP_setup.sh"
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

mkdir -p "$BIRDDOG_ROOT/mesh"

cat > "$BIRDDOG_ROOT/mesh/mesh.conf" << EOF
MESH_IP="${MESH_IP}/24"
EOF

echo "  mesh.conf written — IP: $MESH_IP/24"

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
echo "Rebooting in 3 seconds..."
echo "====================================="
sleep 3
reboot
