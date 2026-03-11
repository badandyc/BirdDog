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
BDM_HOST_ARG=""

# -------------------------------
# Reuse hostname
# -------------------------------

if [[ "$CURRENT_HOST" =~ ^bd[cm]-[0-9]{2}$ ]]; then
    echo ""
    echo "Existing BirdDog hostname detected: $CURRENT_HOST"
    read -p "Keep hostname? (y/n): " KEEP_HOST

    if [[ "$KEEP_HOST" =~ ^[Yy]$ ]]; then
        HOSTNAME_INPUT="$CURRENT_HOST"
        REUSE_HOST=1
    fi
fi

# -------------------------------
# Reuse BDM association
# -------------------------------

if [[ -f "$BDC_CONFIG" ]]; then
    source "$BDC_CONFIG"

    echo ""
    echo "Existing BDM link detected: $BDM_HOST"
    read -p "Keep BDM association? (y/n): " KEEP_BDM

    if [[ "$KEEP_BDM" =~ ^[Yy]$ ]]; then
        REUSE_BDM=1
        BDM_HOST_ARG="$BDM_HOST"
    fi
fi

# -------------------------------
# Hostname input if needed
# -------------------------------

if [[ "$REUSE_HOST" != "1" ]]; then

    read -p "Enter BirdDog hostname (bdm-## or bdc-##): " HOSTNAME_INPUT

    if [[ ! "$HOSTNAME_INPUT" =~ ^bd[cm]-[0-9]{2}$ ]]; then
        echo "Invalid hostname format. Example: bdc-01"
        exit 1
    fi
fi

NODE_NUM=$(echo "$HOSTNAME_INPUT" | grep -oE '[0-9]{2}')

echo ""
echo "Setting hostname to $HOSTNAME_INPUT"

hostnamectl set-hostname "$HOSTNAME_INPUT"

sed -i "s/^127.0.1.1.*/127.0.1.1   $HOSTNAME_INPUT/" /etc/hosts || \
echo "127.0.1.1   $HOSTNAME_INPUT" >> /etc/hosts

# -------------------------------
# ROLE EXECUTION
# -------------------------------

if [[ "$HOSTNAME_INPUT" == bdc-* ]]; then

    echo "[BDC] Running installer..."

    if [[ "$REUSE_BDM" == "1" ]]; then
        bash /opt/birddog/bdc/bdc_fresh_install_setup.sh "$HOSTNAME_INPUT" "$BDM_HOST_ARG"
    else
        bash /opt/birddog/bdc/bdc_fresh_install_setup.sh "$HOSTNAME_INPUT"
    fi

elif [[ "$HOSTNAME_INPUT" == bdm-* ]]; then

    echo "[BDM] Running installer..."

    bash /opt/birddog/bdm/bdm_initial_setup.sh "$HOSTNAME_INPUT"
    bash /opt/birddog/bdm/bdm_AP_setup.sh
    bash /opt/birddog/bdm/bdm_mediamtx_setup.sh
    bash /opt/birddog/bdm/bdm_web_setup.sh

else
    echo "Unknown role"
    exit 1
fi

echo ""
echo "====================================="
echo "Device configuration complete"
echo "====================================="

echo "Rebooting in 10 seconds..."
sleep 10
reboot -f
