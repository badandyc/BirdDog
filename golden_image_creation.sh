#!/bin/bash
set -e

echo "=== BirdDog Golden Image Creation ==="

echo "[1/11] Installing required packages (if missing)..."

sudo apt update

for pkg in ffmpeg rpicam-apps avahi-daemon nginx hostapd dnsmasq git; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo " - $pkg already installed"
    else
        echo " - installing $pkg"
        sudo apt install -y "$pkg"
    fi
done

echo "[1/11] Package check complete."


echo "[2/11] Creating BirdDog directory structure..."

sudo mkdir -p /opt/birddog/{bdm,bdc,mesh,mediamtx,web,version}
sudo chmod -R 777 /opt/birddog

echo "[2/11] Directory structure created."


echo "[3/11] Switching to /opt/birddog..."

cd /opt/birddog

echo "[3/11] Working directory set."


echo "[4/11] Cleaning previous scripts..."

rm -f /opt/birddog/bdm/*.sh || true
rm -f /opt/birddog/bdc/*.sh || true
rm -f /opt/birddog/mesh/*.sh || true
rm -f /opt/birddog/start.sh || true

echo "[4/11] Cleanup complete."


echo "[5/11] Downloading BDM scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_initial_setup.sh?$(date +%s)" -o bdm/bdm_initial_setup.sh
echo " - bdm_initial_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_AP_setup.sh?$(date +%s)" -o bdm/bdm_AP_setup.sh
echo " - bdm_AP_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_mediamtx_setup.sh?$(date +%s)" -o bdm/bdm_mediamtx_setup.sh
echo " - bdm_mediamtx_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_web_setup.sh?$(date +%s)" -o bdm/bdm_web_setup.sh
echo " - bdm_web_setup.sh downloaded"

echo "[5/11] BDM scripts complete."


echo "[6/11] Downloading BDC scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdc/bdc_fresh_install_setup.sh?$(date +%s)" -o bdc/bdc_fresh_install_setup.sh
echo " - bdc_fresh_install_setup.sh downloaded"

echo "[6/11] BDC scripts complete."


echo "[7/11] Downloading mesh scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/mesh/add_mesh_network.sh?$(date +%s)" -o mesh/add_mesh_network.sh
echo " - add_mesh_network.sh downloaded"

echo "[7/11] Mesh scripts complete."


echo "[8/11] Downloading start script..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/start.sh?$(date +%s)" -o start.sh
echo " - start.sh downloaded"

echo "[8/11] Start script complete."


echo "[9/11] Setting executable permissions..."

sudo chmod +x /opt/birddog/start.sh
sudo chmod +x /opt/birddog/bdm/*.sh
sudo chmod +x /opt/birddog/bdc/*.sh
sudo chmod +x /opt/birddog/mesh/*.sh

echo "[9/11] Permissions applied."


echo "[10/11] Verifying installation..."

echo "--- /opt/birddog ---"
ls -1 /opt/birddog

echo "--- /opt/birddog/bdm ---"
ls -1 /opt/birddog/bdm

echo "--- /opt/birddog/bdc ---"
ls -1 /opt/birddog/bdc

echo "--- /opt/birddog/mesh ---"
ls -1 /opt/birddog/mesh

echo "[10/11] Verification complete."


echo "[11/11] Writing BirdDog version..."

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
echo ""
echo "Run setup with:"
echo "sudo /opt/birddog/start.sh"
echo "====================================="
