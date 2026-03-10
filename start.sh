#!/bin/bash
set -e

echo ""
echo "====================================="
echo "BirdDog Master Bootstrap"
echo "====================================="
echo ""

# Hostname input loop
while true; do

    read -p "Enter hostname (bdm-01, bdc-01, etc): " HOSTNAME_INPUT

    if [[ -z "$HOSTNAME_INPUT" ]]; then
        echo ""
        echo "Hostname cannot be empty."
        echo ""
        continue
    fi

    if [[ ! "$HOSTNAME_INPUT" =~ ^bd[mc]-[0-9]{2}$ ]]; then
        echo ""
        echo "Invalid hostname format."
        echo "Expected examples:"
        echo "  bdm-01"
        echo "  bdc-01"
        echo ""
        continue
    fi

    # Valid hostname
    break

done


echo ""
echo "Setting hostname to $HOSTNAME_INPUT"
echo ""

sudo hostnamectl set-hostname "$HOSTNAME_INPUT"

NODE_NUM=$(echo "$HOSTNAME_INPUT" | grep -oE '[0-9]+$')

echo "Node number detected: $NODE_NUM"

echo ""
echo "=== Determining node role ==="

ROLE_PREFIX=$(echo "$HOSTNAME_INPUT" | cut -d'-' -f1)

if [[ "$ROLE_PREFIX" == "bdm" ]]; then
    ROLE="BDM"
elif [[ "$ROLE_PREFIX" == "bdc" ]]; then
    ROLE="BDC"
else
    echo "Unable to determine node role."
    exit 1
fi

echo "Detected $ROLE node"
echo ""

# Run installer
if [[ "$ROLE" == "BDM" ]]; then

    echo "[1/2] Running BDM setup..."
    echo ""

    sudo bash /opt/birddog/bdm/bdm_initial_setup.sh "$HOSTNAME_INPUT"

elif [[ "$ROLE" == "BDC" ]]; then

    echo "[1/2] Running BDC setup..."
    echo ""

    sudo bash /opt/birddog/bdc/bdc_fresh_install_setup.sh "$HOSTNAME_INPUT"

fi


echo ""
echo "[2/2] Configuring Mesh Network..."
echo ""

sudo bash /opt/birddog/mesh/add_mesh_network.sh "$HOSTNAME_INPUT"

echo ""
echo "====================================="
echo "BirdDog Bootstrap Complete"
echo "Hostname: $HOSTNAME_INPUT"
echo "Role: $ROLE"
echo "====================================="
echo ""
