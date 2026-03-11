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

# -------------------------------------------------
# Existing hostname detection
# -------------------------------------------------

if [[ "$CURRENT_HOST" == bdc-* || "$CURRENT_HOST" == bdm-* ]]; then

    echo ""
    echo "Existing BirdDog hostname detected: $CURRENT_HOST"
    read -p "Keep hostname? (y/n): " KEEP_HOST

    if [[ "$KEEP_HOST" =~ ^[Yy]$ ]]; then
        HOSTNAME_INPUT="$CURRENT_HOST"
        REUSE_HOST=1
    fi

fi


# -------------------------------------------------
# Existing BDM association detection (BDC only)
# -------------------------------------------------

if [[ -f "$BDC_CONFIG" ]]; then

    source "$BDC_CONFIG"

    echo ""
    echo "Existing BDM link detected: $BDM_HOST"
    read -p "Keep BDM association? (y/n): " KEEP_BDM

    if [[ "$KEEP_BDM" =~ ^[Yy]$ ]]; then
        REUSE_BDM=1
    fi

fi


# -------------------------------------------------
# Hostname prompt if not reusing
# -------------------------------------------------

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


# -------------------------------------------------
# Role install
# -------------------------------------------------

if [[ "$HOSTNAME_INPUT" == bdc-* ]]; then

    echo "[1/1] Running BDC setup..."

    if [[ "$REUSE_BDM" == "1" ]]; then
        bash /opt/birddog/bdc/bdc_fresh_install_setup.sh "$HOSTNAME_INPUT" "$BDM_HOST"
    else
        bash /opt/birddog/bdc/bdc_fresh_install_setup.sh "$HOSTNAME_INPUT"
    fi

elif [[ "$HOSTNAME_INPUT" == bdm-* ]]; then

    echo "[1/1] Running BDM setup..."

    bash /opt/birddog/bdm/bdm_initial_setup.sh "$HOSTNAME_INPUT"
    bash /opt/birddog/bdm/bdm_AP_setup.sh
    bash /opt/birddog/bdm/bdm_mediamtx_setup.sh
    bash /opt/birddog/bdm/bdm_web_setup.sh

else
    echo "Invalid hostname prefix"
    exit 1
fi


echo ""
echo "====================================="
echo "Device configuration complete"
echo "====================================="
echo ""

echo "System will reboot in 10 seconds..."
sleep 10
reboot -f
