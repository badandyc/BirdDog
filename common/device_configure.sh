#!/bin/bash
set -e

echo "====================================="
echo "BirdDog Device Configuration"
echo "====================================="

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo birddog configure"
    exit 1
fi

read -p "Enter BirdDog hostname (bdm-## or bdc-##): " HOSTNAME_INPUT

if [[ -z "$HOSTNAME_INPUT" ]]; then
    echo "Hostname not provided"
    exit 1
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
if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1   $HOSTNAME_INPUT/" /etc/hosts
else
    echo "127.0.1.1   $HOSTNAME_INPUT" >> /etc/hosts
fi

echo ""

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
