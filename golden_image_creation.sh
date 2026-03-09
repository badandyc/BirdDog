#!/bin/bash
set -e

echo "=== BirdDog Golden Image Creation ==="

echo "[1/8] Installing required packages (if missing)..."

sudo apt update

for pkg in ffmpeg rpicam-apps avahi-daemon nginx hostapd dnsmasq; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo " - $pkg already installed"
    else
        echo " - installing $pkg"
        sudo apt install -y "$pkg"
    fi
done

echo "[1/8] Package check complete."

echo "[2/8] Creating BirdDog directory structure..."

sudo mkdir -p /opt/birddog/{bdm,bdc,mediamtx,web}
sudo chmod -R 777 /opt/birddog

echo "[2/8] Directory structure created."

echo "[3/8] Switching to /opt/birddog..."

cd /opt/birddog

echo "[3/8] Working directory set."

echo "[4/8] Cleaning previous scripts..."

rm -f /opt/birddog/bdm/*.sh || true
rm -f /opt/birddog/bdc/*.sh || true
rm -f /opt/birddog/start.sh || true

echo "[4/8] Cleanup complete."

echo "[5/8] Downloading BDM scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_initial_setup.sh?$(date +%s)" -o bdm/bdm_initial_setup.sh
echo " - bdm_initial_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_AP_setup.sh?$(date +%s)" -o bdm/bdm_AP_setup.sh
echo " - bdm_AP_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_mediamtx_setup.sh?$(date +%s)" -o bdm/bdm_mediamtx_setup.sh
echo " - bdm_mediamtx_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_web_setup.sh?$(date +%s)" -o bdm/bdm_web_setup.sh
echo " - bdm_web_setup.sh downloaded"

echo "[5/8] BDM scripts complete."

echo "[6/8] Downloading BDC scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdc/bdc_fresh_install_setup.sh?$(date +%s)" -o bdc/bdc_fresh_install_setup.sh
echo " - bdc_fresh_install_setup.sh downloaded"

echo "[6/8] BDC scripts complete."

echo "[7/8] Downloading start script..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/start.sh?$(date +%s)" -o start.sh
echo " - start.sh downloaded"

echo "[7/8] Start script complete."

echo "[8/8] Setting executable permissions..."

sudo chmod +x /opt/birddog/start.sh
sudo chmod +x /opt/birddog/bdm/*.sh
sudo chmod +x /opt/birddog/bdc/*.sh

echo "[8/8] Permissions applied."

echo "[9/9] Verifying installation..."

echo "--- /opt/birddog ---"
ls -1 /opt/birddog

echo "--- /opt/birddog/bdm ---"
ls -1 /opt/birddog/bdm

echo "--- /opt/birddog/bdc ---"
ls -1 /opt/birddog/bdc

echo "[9/9] Verification complete."

echo "====================================="
echo "BirdDog Golden Image Setup Complete"
echo "Scripts installed to /opt/birddog"
echo ""
echo "Run setup with:"
echo "sudo /opt/birddog/start.sh"
echo "====================================="
