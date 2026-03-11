#!/bin/bash
set -e

echo "=== BirdDog Golden Image Creation ==="

echo "[1/13] Installing required packages (if missing)..."

sudo apt update

for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo " - $pkg already installed"
    else
        echo " - installing $pkg"
        sudo apt install -y "$pkg"
    fi
done

echo "[1/13] Package check complete."


echo "[2/13] Creating BirdDog directory structure..."

sudo mkdir -p /opt/birddog/{bdm,bdc,mesh,common,mediamtx,web,version}
sudo chmod -R 777 /opt/birddog

echo "[2/13] Directory structure created."


echo "[3/13] Switching to /opt/birddog..."

cd /opt/birddog

echo "[3/13] Working directory set."


echo "[4/13] Cleaning previous scripts..."

rm -f /opt/birddog/bdm/*.sh || true
rm -f /opt/birddog/bdc/*.sh || true
rm -f /opt/birddog/mesh/*.sh || true
rm -f /opt/birddog/common/*.sh || true

echo "[4/13] Cleanup complete."


echo "[5/13] Downloading BDM scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_initial_setup.sh?$(date +%s)" -o bdm/bdm_initial_setup.sh
echo " - bdm_initial_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_AP_setup.sh?$(date +%s)" -o bdm/bdm_AP_setup.sh
echo " - bdm_AP_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_mediamtx_setup.sh?$(date +%s)" -o bdm/bdm_mediamtx_setup.sh
echo " - bdm_mediamtx_setup.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_web_setup.sh?$(date +%s)" -o bdm/bdm_web_setup.sh
echo " - bdm_web_setup.sh downloaded"

echo "[5/13] BDM scripts complete."


echo "[6/13] Downloading BDC scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdc/bdc_fresh_install_setup.sh?$(date +%s)" -o bdc/bdc_fresh_install_setup.sh
echo " - bdc_fresh_install_setup.sh downloaded"

echo "[6/13] BDC scripts complete."


echo "[7/13] Downloading mesh scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/mesh/add_mesh_network.sh?$(date +%s)" -o mesh/add_mesh_network.sh
echo " - add_mesh_network.sh downloaded"

echo "[7/13] Mesh scripts complete."


echo "[8/13] Downloading common scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/device_configure.sh?$(date +%s)" -o common/device_configure.sh
echo " - device_configure.sh downloaded"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/radio_map_setup.sh?$(date +%s)" -o common/radio_map_setup.sh
echo " - radio_map_setup.sh downloaded"

echo "[8/13] Common scripts complete."


echo "[9/13] Installing BirdDog CLI..."

cat << 'EOF' | sudo tee /usr/local/bin/birddog > /dev/null
#!/bin/bash

echo ""
echo "================================="
echo "BirdDog CLI"
echo "================================="

case "$1" in

install)
    echo "Running BirdDog installer..."
    sudo bash /opt/birddog/common/golden_image_creation.sh
;;

configure)
    echo "Running device configuration..."
    sudo bash /opt/birddog/common/device_configure.sh
;;

update)
    echo "Updating BirdDog scripts..."
    sudo birddog-update
;;

restart)
    echo "Restarting BirdDog services..."
    sudo systemctl restart mediamtx 2>/dev/null || true
    sudo systemctl restart nginx 2>/dev/null || true
    sudo systemctl restart birddog-stream 2>/dev/null || true
;;

status)
    echo ""
    echo "BirdDog Version:"
    cat /opt/birddog/version/VERSION 2>/dev/null || echo "Unknown"

    echo ""
    echo "Mesh:"
    mesh status 2>/dev/null || echo "Mesh not configured"

    echo ""
    echo "MediaMTX:"
    systemctl is-active mediamtx 2>/dev/null || true

    echo "Web Server:"
    systemctl is-active nginx 2>/dev/null || true
;;

""|help)
    echo ""
    echo "Commands:"
    echo ""
    echo "birddog install     → install BirdDog software"
    echo "birddog configure   → run device configuration"
    echo "birddog update      → update scripts"
    echo "birddog restart     → restart services"
    echo "birddog status      → system status"
    echo "birddog help        → show this menu"
    echo ""
;;

*)
    echo "Unknown command"
;;

esac
EOF

sudo chmod +x /usr/local/bin/birddog

echo "BirdDog CLI installed"


echo "[10/13] Setting executable permissions..."

sudo chmod +x /opt/birddog/common/*.sh
sudo chmod +x /opt/birddog/bdm/*.sh
sudo chmod +x /opt/birddog/bdc/*.sh
sudo chmod +x /opt/birddog/mesh/*.sh

echo "[10/13] Permissions applied."


echo "[11/13] Verifying installation..."

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

echo "[11/13] Verification complete."


echo "[12/13] Writing BirdDog version..."

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
echo "[13/13] Launch BirdDog Device Configure?"
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
        echo "Invalid response."
        echo "Run manually with:"
        echo "sudo /opt/birddog/common/device_configure.sh"
        ;;
esac
