#!/bin/bash
set -e

echo "=== BirdDog Golden Image Creation ==="

echo "[1/10] Installing required packages (if missing)..."

sudo apt update

for pkg in ffmpeg rpicam-apps avahi-daemon nginx hostapd dnsmasq git; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo " - $pkg already installed"
    else
        echo " - installing $pkg"
        sudo apt install -y "$pkg"
    fi
done

echo "[1/10] Package check complete."


echo "[2/10] Creating BirdDog directory structure..."

sudo mkdir -p /opt/birddog/{bdm,bdc,mediamtx,web,version}
sudo chmod -R 777 /opt/birddog

echo "[2/10] Directory structure created."


echo "[3/10] Switching to /opt/birddog..."

cd /opt/birddog

echo "[3/10] Working directory set."


echo "[4/10] Cleaning previous scripts..."

rm -f /opt/birddog/bdm/*.sh || true
rm -f /opt/birddog/bdc/*.sh || true
rm -f /opt/birddog/start.sh || true

echo "[4/10] Cleanup complete."


echo "[5/10] Downloading BDM scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_initial_setup.sh?$(date +%s)" -o bdm/bdm_initial_setup.sh
echo " - bdm_initial_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_AP_setup.sh?$(date +%s)" -o bdm/bdm_AP_setup.sh
echo " - bdm_AP_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_mediamtx_setup.sh?$(date +%s)" -o bdm/bdm_mediamtx_setup.sh
echo " - bdm_mediamtx_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_web_setup.sh?$(date +%s)" -o bdm/bdm_web_setup.sh
echo " - bdm_web_setup.sh downloaded"

echo "[5/10] BDM scripts complete."


echo "[6/10] Downloading BDC scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdc/bdc_fresh_install_setup.sh?$(date +%s)" -o bdc/bdc_fresh_install_setup.sh
echo " - bdc_fresh_install_setup.sh downloaded"

echo "[6/10] BDC scripts complete."


echo "[7/10] Downloading start script..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/start.sh?$(date +%s)" -o start.sh
echo " - start.sh downloaded"

echo "[7/10] Start script complete."


echo "[8/10] Setting executable permissions..."

sudo chmod +x /opt/birddog/start.sh
sudo chmod +x /opt/birddog/bdm/*.sh
sudo chmod +x /opt/birddog/bdc/*.sh

echo "[8/10] Permissions applied."


echo "[9/10] Verifying installation..."

echo "--- /opt/birddog ---"
ls -1 /opt/birddog

echo "--- /opt/birddog/bdm ---"
ls -1 /opt/birddog/bdm

echo "--- /opt/birddog/bdc ---"
ls -1 /opt/birddog/bdc

echo "[9/10] Verification complete."


echo "[10/10] Writing BirdDog version..."

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
