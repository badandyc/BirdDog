#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash /opt/birddog/start.sh"
  exit 1
fi

echo ""
echo "====================================="
echo "BirdDog Master Bootstrap"
echo "====================================="
echo ""

read -p "Enter hostname (bdm-01, bdc-01, etc): " HOSTNAME_INPUT

if [[ -z "$HOSTNAME_INPUT" ]]; then
  echo "Hostname required"
  exit 1
fi

echo "$HOSTNAME_INPUT" > /etc/hostname
hostname "$HOSTNAME_INPUT"

if grep -q "^127.0.1.1" /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1    $HOSTNAME_INPUT/" /etc/hosts
else
  echo "127.0.1.1    $HOSTNAME_INPUT" >> /etc/hosts
fi

echo "Hostname set to $HOSTNAME_INPUT"
echo ""

echo "=== Determining node role ==="

if [[ $HOSTNAME_INPUT == bdm-* ]]; then

  echo "Detected BDM node"
  
  echo "[1/5] Running BDM initial setup..."
  bash /opt/birddog/bdm/bdm_initial_setup.sh "$HOSTNAME_INPUT"

  echo "[2/5] Configuring Access Point..."
  bash /opt/birddog/bdm/bdm_AP_setup.sh "$HOSTNAME_INPUT"

  echo "[3/5] Configuring MediaMTX..."
  bash /opt/birddog/bdm/bdm_mediamtx_setup.sh "$HOSTNAME_INPUT"

  echo "[4/5] Installing Web Dashboard..."
  bash /opt/birddog/bdm/bdm_web_setup.sh "$HOSTNAME_INPUT"

  echo "[5/5] Configuring Mesh Network..."
  bash /opt/birddog/add_mesh_network.sh "$HOSTNAME_INPUT"


elif [[ $HOSTNAME_INPUT == bdc-* ]]; then

  echo "Detected BDC node"
  
  echo "[1/1] Running BDC setup..."
  bash /opt/birddog/bdc/bdc_fresh_install_setup.sh "$HOSTNAME_INPUT"

else

  echo "Unknown node type"
  echo "Use hostname starting with:"
  echo "bdm-XX  (master)"
  echo "bdc-XX  (camera node)"
  exit 1

fi

echo ""
echo "====================================="
echo "BirdDog Bootstrap Complete"
echo "Hostname: $(hostname)"
echo "====================================="
