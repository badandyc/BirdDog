#!/bin/bash
set -e

echo "=== BirdDog Golden Image Creation ==="

echo "[1/12] Installing required packages (if missing)..."

sudo apt update

for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo " - $pkg already installed"
    else
        echo " - installing $pkg"
        sudo apt install -y "$pkg"
    fi
done

echo "[1/12] Package check complete."


echo "[2/12] Creating BirdDog directory structure..."

sudo mkdir -p /opt/birddog/{bdm,bdc,mesh,common,mediamtx,web,version}
sudo chmod -R 777 /opt/birddog

echo "[2/12] Directory structure created."


echo "[3/12] Switching to /opt/birddog..."

cd /opt/birddog

echo "[3/12] Working directory set."


echo "[4/12] Cleaning previous scripts..."

rm -f /opt/birddog/bdm/*.sh || true
rm -f /opt/birddog/bdc/*.sh || true
rm -f /opt/birddog/mesh/*.sh || true
rm -f /opt/birddog/common/*.sh || true

echo "[4/12] Cleanup complete."


echo "[5/12] Downloading BDM scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_initial_setup.sh?$(date +%s)" -o bdm/bdm_initial_setup.sh
echo " - bdm_initial_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_AP_setup.sh?$(date +%s)" -o bdm/bdm_AP_setup.sh
echo " - bdm_AP_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_mediamtx_setup.sh?$(date +%s)" -o bdm/bdm_mediamtx_setup.sh
echo " - bdm_mediamtx_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_web_setup.sh?$(date +%s)" -o bdm/bdm_web_setup.sh
echo " - bdm_web_setup.sh downloaded"

echo "[5/12] BDM scripts complete."


echo "[6/12] Downloading BDC scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdc/bdc_fresh_install_setup.sh?$(date +%s)" -o bdc/bdc_fresh_install_setup.sh
echo " - bdc_fresh_install_setup.sh downloaded"

echo "[6/12] BDC scripts complete."


echo "[7/12] Downloading mesh scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/mesh/add_mesh_network.sh?$(date +%s)" -o mesh/add_mesh_network.sh
echo " - add_mesh_network.sh downloaded"

echo "[7/12] Mesh scripts complete."


echo "[8/12] Downloading common scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/device_configure.sh?$(date +%s)" -o common/start.sh
echo " - start.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/radio_map_setup.sh?$(date +%s)" -o common/radio_map_setup.sh
echo " - radio_map_setup.sh downloaded"

echo "[8/12] Common scripts complete."


echo "[9/12] Setting executable permissions..."

sudo chmod +x /opt/birddog/common/device_configure.sh
sudo chmod +x /opt/birddog/common/*.sh
sudo chmod +x /opt/birddog/bdm/*.sh
sudo chmod +x /opt/birddog/bdc/*.sh
sudo chmod +x /opt/birddog/mesh/*.sh

echo "[9/12] Permissions applied."


echo "[10/12] Verifying installation..."

echo "--- /opt/birddog ---"
ls -1 /opt/birddog

echo "--- /opt/birddog/common ---"
ls -1 /opt/birddog/common

echo "--- /opt/birddog/bdm ---"
ls -1 /opt/birddog/bdm

echo "--- /opt/birddog/bdc ---"
ls -1 /opt/birddog/bdc

echo "--- /opt/birddog/mesh ---"
ls -1 /opt/birddog/mesh

echo "[10/12] Verification complete."


echo "[11/12] Writing BirdDog version..."

VERSION_DIR="/opt/birddog/version"
VERSION_FILE="$VERSION_DIR/VERSION"

mkdir -p $VERSION_DIR

VERSION="BirdDog_$(date +%Y.%m.%d)_$(git rev-parse --short HEAD 2>/dev/null || echo manual)"

echo "$VERSION" | sudo tee $VERSION_FILE > /dev/null

echo "Version written:"
cat $VERSION_FILE


echo "====================================="
echo "BirdDog Golden Image Setup Complete"
echo "Scripts installed to /opt/birddog"
echo "====================================="


echo ""
echo "[12/12] Launch BirdDog Device_Configure?"
echo ""

read -p "Start setup now (run device_configure.sh)? [Y/N]: " START_NOW

case "$START_NOW" in
    [Yy]* )
        echo ""
        echo "Launching BirdDog setup..."
        echo ""
        sudo /opt/birddog/common/device_configure.sh
        ;;
    [Nn]* )
        echo ""
        echo "Setup skipped."
        echo ""
        echo "You can run it later with:"
        echo "sudo /opt/birddog/common/device_configure.sh"
        ;;
    * )
        echo ""
        echo "Invalid response. Exiting without running setup."
        echo "Run manually with:"
        echo "sudo /opt/birddog/common/device_configure.sh"
        ;;
esac
