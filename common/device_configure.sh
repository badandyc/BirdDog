#!/bin/bash
set -e

echo "====================================="
echo "BirdDog Device Configuration"
echo "====================================="

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo birddog configure"
    exit 1
fi

CURRENT_HOST=$(hostname)
BDC_CONFIG="/opt/birddog/bdc/bdc.conf"

REUSE_HOST=0
REUSE_BDM=0

if [[ "$CURRENT_HOST" == bdc-* || "$CURRENT_HOST" == bdm-* ]]; then

    echo ""
    echo "Existing BirdDog hostname detected: $CURRENT_HOST"
    read -p "Keep hostname? (y/n): " KEEP_HOST

    if [[ "$KEEP_HOST" =~ ^[Yy]$ ]]; then
        HOSTNAME_INPUT="$CURRENT_HOST"
        REUSE_HOST=1
    fi

fi

if [[ -f "$BDC_CONFIG" ]]; then
    source "$BDC_CONFIG"

    echo ""
    echo "Existing BDM link detected: $BDM_HOST"
    read -p "Keep BDM association? (y/n): " KEEP_BDM

    if [[ "$KEEP_BDM" =~ ^[Yy]$ ]]; then
        REUSE_BDM=1
    fi
fi


if [[ "$REUSE_HOST" != "1" ]]; then

    read -p "Enter BirdDog hostname (bdm-## or bdc-##): " HOSTNAME_INPUT

    if [[ -z "$HOSTNAME_INPUT" ]]; then
        echo "Hostname not provided"
        exit 1
    fi

fi


NODE_NUM=$(echo "$HOSTNAME_INPUT" | grep -oE '[0-9]+$')

if [[ -z "$NODE_NUM" ]]; then
    echo "Hostname must end in number"
    exit 1
fi


echo ""
echo "Setting hostname to $HOSTNAME_INPUT"
hostnamectl set-hostname "$HOSTNAME_INPUT"

sed -i "s/^127.0.1.1.*/127.0.1.1   $HOSTNAME_INPUT/" /etc/hosts || \
echo "127.0.1.1   $HOSTNAME_INPUT" >> /etc/hosts


if [[ "$HOSTNAME_INPUT" == bdc-* ]]; then

    echo "[1/2] Running BDC setup..."

    if [[ "$REUSE_BDM" == "1" ]]; then
        bash /opt/birddog/bdc/bdc_fresh_install_setup.sh "$HOSTNAME_INPUT" "$BDM_HOST"
    else
        bash /opt/birddog/bdc/bdc_fresh_install_setup.sh "$HOSTNAME_INPUT"
    fi

    echo "[2/2] Installing mesh network..."
    bash /opt/birddog/mesh/add_mesh_network.sh "$HOSTNAME_INPUT"

fi

echo ""
echo "Device configuration complete"
echo ""
