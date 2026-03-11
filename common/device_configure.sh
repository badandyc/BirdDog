#!/bin/bash
set -e

echo "====================================="
echo "BirdDog Device Configuration"
echo "====================================="

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo birddog configure"
    exit 1
fi

BDC_CONFIG="/opt/birddog/bdc/bdc.conf"

CURRENT_HOST=$(hostname)

REUSE_HOST=0
REUSE_BDM=0

# --------------------------------------------------
# Hostname reuse detection
# --------------------------------------------------

if [[ "$CURRENT_HOST" =~ ^bd[cm]-[0-9]{2}$ ]]; then
    echo ""
    echo "Existing BirdDog hostname detected: $CURRENT_HOST"
    read -p "Keep hostname? (y/n): " KEEP_HOST
    if [[ "$KEEP_HOST" =~ ^[Yy]$ ]]; then
        HOSTNAME_INPUT="$CURRENT_HOST"
        REUSE_HOST=1
    fi
fi

# --------------------------------------------------
# New hostname entry + validation
# --------------------------------------------------

if [[ "$REUSE_HOST" != "1" ]]; then
    read -p "Enter BirdDog hostname (bdm-## or bdc-##): " HOSTNAME_INPUT

    if [[ ! "$HOSTNAME_INPUT" =~ ^bd[cm]-[0-9]{2}$ ]]; then
        echo "Invalid hostname format (must be bdm-01 or bdc-01)"
        exit 1
    fi
fi

ROLE=$(echo "$HOSTNAME_INPUT" | cut -d- -f1)
NODE_NUM=$(echo "$HOSTNAME_INPUT" | cut -d- -f2)
STREAM_NAME="cam${NODE_NUM}"

echo ""
echo "Setting hostname to $HOSTNAME_INPUT"

hostnamectl set-hostname "$HOSTNAME_INPUT"

if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1   $HOSTNAME_INPUT/" /etc/hosts
else
    echo "127.0.1.1   $HOSTNAME_INPUT" >> /etc/hosts
fi


# --------------------------------------------------
# ROLE: BDC
# --------------------------------------------------

if [[ "$ROLE" == "bdc" ]]; then

    if [[ -f "$BDC_CONFIG" ]]; then
        source "$BDC_CONFIG"
        echo ""
        echo "Existing BDM link detected: $BDM_HOST"
        read -p "Keep BDM association? (y/n): " KEEP_BDM
        if [[ "$KEEP_BDM" =~ ^[Yy]$ ]]; then
            REUSE_BDM=1
        else
            unset BDM_HOST
        fi
    fi

    if [[ "$REUSE_BDM" != "1" ]]; then
        read -p "Enter BDM hostname (without .local): " BDM_NAME

        if [[ ! "$BDM_NAME" =~ ^bdm-[0-9]{2}$ ]]; then
            echo "Invalid BDM hostname format"
            exit 1
        fi

        BDM_HOST="${BDM_NAME}.local"
    fi

    echo ""
    echo "[BDC] Running setup..."
    bash /opt/birddog/bdc/bdc_fresh_install_setup.sh \
        "$HOSTNAME_INPUT" \
        "$BDM_HOST" \
        "$STREAM_NAME"

    echo ""
    echo "[BDC] Installing mesh..."
    bash /opt/birddog/mesh/add_mesh_network.sh "$HOSTNAME_INPUT"

# --------------------------------------------------
# ROLE: BDM
# --------------------------------------------------

elif [[ "$ROLE" == "bdm" ]]; then

    echo ""
    echo "[BDM] Running setup..."

    bash /opt/birddog/bdm/bdm_initial_setup.sh "$HOSTNAME_INPUT"
    bash /opt/birddog/bdm/bdm_AP_setup.sh
    bash /opt/birddog/bdm/bdm_mediamtx_setup.sh
    bash /opt/birddog/bdm/bdm_web_setup.sh

    echo ""
    echo "[BDM] Installing mesh..."
    bash /opt/birddog/mesh/add_mesh_network.sh "$HOSTNAME_INPUT"

else
    echo "Unknown role"
    exit 1
fi


echo ""
echo "====================================="
echo "Device configuration complete."
echo "Rebooting in 10 seconds..."
echo "====================================="
sleep 10
reboot -f
