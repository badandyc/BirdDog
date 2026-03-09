#!/bin/bash
set -e

echo "=== BirdDog Golden Image Creation ==="

echo "[1/7] Installing required packages..."
#sudo apt update
#sudo apt install -y ffmpeg rpicam-apps avahi-daemon nginx hostapd dnsmasq
echo "[1/7] Package installation complete."

echo "[2/7] Creating BirdDog directory structure..."
sudo mkdir -p /opt/birddog/{bdm,bdc,mediamtx,web}
sudo chmod -R 777 /opt/birddog
echo "[2/7] Directory structure created."

echo "[3/7] Switching to /opt/birddog..."
cd /opt/birddog
echo "[3/7] Working directory set."

echo "[4/7] Downloading BDM scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_initial_setup.sh?$(date +%s)" -o bdm/bdm_initial_setup.sh
echo " - bdm_initial_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_AP_setup.sh?$(date +%s)" -o bdm/bdm_AP_setup.sh
echo " - bdm_AP_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_mediamtx_setup.sh?$(date +%s)" -o bdm/bdm_mediamtx_setup.sh
echo " - bdm_mediamtx_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_web_setup.sh?$(date +%s)" -o bdm/bdm_web_setup.sh
echo " - bdm_web_setup.sh downloaded"

echo "[4/7] BDM scripts complete."

echo "[5/7] Downloading BDC scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdc/bdc_fresh_install_setup.sh?$(date +%s)" -o bdc/bdc_fresh_install_setup.sh
echo " - bdc_fresh_install_setup.sh downloaded"

echo "[5/7] BDC scripts complete."

echo "[6/7] Downloading start script..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/start.sh?$(date +%s)" -o start.sh
echo " - start.sh downloaded"

echo "[6/7] Start script complete."

echo "[7/7] Setting executable permissions..."

sudo chmod +x /opt/birddog/start.sh
sudo chmod +x /opt/birddog/bdm/*.sh
sudo chmod +x /opt/birddog/bdc/*.sh

echo "[7/7] Permissions applied."

echo "====================================="
echo "BirdDog Golden Image Setup Complete"
echo "Scripts installed to /opt/birddog"
echo ""
echo "Run setup with:"
echo "sudo /opt/birddog/start.sh"
echo "====================================="
