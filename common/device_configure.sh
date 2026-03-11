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

if [[ -f "$BDC_CONFIG" ]]; then

    source "$BDC_CONFIG"

    echo ""
    echo "Existing configuration detected:"
    echo "BDC Hostname : $BDC_HOSTNAME"
    echo "BDM Host     : $BDM_HOST"
    echo ""

    read -p "Keep this configuration? (y/n): " KEEP

    if [[ "$KEEP" =~ ^[Yy]$ ]]; then
        HOSTNAME_INPUT="$BDC_HOSTNAME"
        SKIP_HOST_PROMPT=1
    else
        SKIP_HOST_PROMPT=0
    fi

else
    SKIP_HOST_PROMPT=0
fi


if [[ "$SKIP_HOST_PROMPT" != "1" ]]; then

    read -p "Enter BirdDog hostname (bdm-## or bdc-##): " HOSTNAME_INPUT

    if [[ -z "$HOSTNAME_INPUT" ]]; then
        echo "Hostname not provided"
        exit 1
    fi

fi


NODE_NUM=$(echo "$HOSTNAME_INPUT" | grep -oE '[0-9]+$')

if [[ -z "$NODE_NUM" ]]; then
    echo "Hostname must end in number (example: bdc-01)"
    exit 1
fi

echo ""
echo "Setting hostname to $HOSTNAME_INPUT"
hostnamectl set-hostname "$HOSTNAME_INPUT"

echo "Updating /etc/hosts..."
sed -i "s/^127.0.1.1.*/127.0.1.1   $HOSTNAME_INPUT/" /etc/hosts || \
echo "127.0.1.1   $HOSTNAME_INPUT" >> /etc/hosts


if [[ "$HOSTNAME_INPUT" == bdm-* ]]; then

    echo "[1/5] Running BDM initial setup..."
    bash /opt/birddog/bdm/bdm_initial_setup.sh "$HOSTNAME_INPUT"

    echo "[2/5] Configuring access point..."
    bash /opt/birddog/bdm/bdm_AP_setup.sh "$HOSTNAME_INPUT"

    echo "[3/5] Installing MediaMTX..."
    bash /opt/birddog/bdm/bdm_mediamtx_setup.sh "$HOSTNAME_INPUT"

    echo "[4/5] Installing web dashboard..."
    bash /opt/birddog/bdm/bdm_web_setup.sh "$HOSTNAME_INPUT"

    echo "[5/5] Installing mesh network..."
    bash /opt/birddog/mesh/add_mesh_network.sh "$HOSTNAME_INPUT"

elif [[ "$HOSTNAME_INPUT" == bdc-* ]]; then

    echo "[1/2] Running BDC setup..."
    bash /opt/birddog/bdc/bdc_fresh_install_setup.sh "$HOSTNAME_INPUT"

    echo "[2/2] Installing mesh network..."
    bash /opt/birddog/mesh/add_mesh_network.sh "$HOSTNAME_INPUT"

else
    echo "Invalid hostname prefix. Must be bdm-## or bdc-##"
    exit 1
fi


echo ""
echo "====================================="
echo "Device configuration complete"
echo "Node: $HOSTNAME_INPUT"
echo "====================================="
echo ""
