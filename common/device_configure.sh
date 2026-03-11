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

if [[ "$CURRENT_HOST" =~ ^bd[cm]-[0-9]{2}$ ]]; then
    echo ""
    echo "Existing BirdDog hostname detected: $CURRENT_HOST"
    read -p "Keep hostname? (y/n): " KEEP_HOST
    [[ "$KEEP_HOST" =~ ^[Yy]$ ]] && HOSTNAME_INPUT="$CURRENT_HOST" && REUSE_HOST=1
fi

if [[ "$REUSE_HOST" != "1" ]]; then
    read -p "Enter BirdDog hostname (bdm-## or bdc-##): " HOSTNAME_INPUT
    [[ ! "$HOSTNAME_INPUT" =~ ^bd[cm]-[0-9]{2}$ ]] && echo "Invalid hostname format" && exit 1
fi

ROLE=$(echo "$HOSTNAME_INPUT" | cut -d- -f1)

hostnamectl set-hostname "$HOSTNAME_INPUT"
sed -i "s/^127.0.1.1.*/127.0.1.1   $HOSTNAME_INPUT/" /etc/hosts || \
echo "127.0.1.1   $HOSTNAME_INPUT" >> /etc/hosts


if [[ "$ROLE" == "bdc" ]]; then

    if [[ -f "$BDC_CONFIG" ]]; then
        source "$BDC_CONFIG"
        echo ""
        echo "Existing BDM link detected: $BDM_HOST"
        read -p "Keep BDM association? (y/n): " KEEP_BDM
        [[ "$KEEP_BDM" =~ ^[Yy]$ ]] && REUSE_BDM=1
    fi

    if [[ "$REUSE_BDM" != "1" ]]; then
        read -p "Enter BDM hostname (without .local): " BDM_NAME
        BDM_HOST="${BDM_NAME}.local"
    fi

    echo "[BDC] Running installer..."
    bash /opt/birddog/bdc/bdc_fresh_install_setup.sh "$HOSTNAME_INPUT" "$BDM_HOST"

elif [[ "$ROLE" == "bdm" ]]; then

    echo "[BDM] Running installer..."
    bash /opt/birddog/bdm/bdm_initial_setup.sh "$HOSTNAME_INPUT"
    bash /opt/birddog/bdm/bdm_AP_setup.sh
    bash /opt/birddog/bdm/bdm_mediamtx_setup.sh
    bash /opt/birddog/bdm/bdm_web_setup.sh
    bash /opt/birddog/mesh/add_mesh_network.sh "$HOSTNAME_INPUT"

else
    echo "Unknown role"
    exit 1
fi

echo ""
echo "Device configuration complete."
echo "Rebooting in 10 seconds..."
sleep 10
reboot -f
