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


echo "[5/12] Downloading BirdDog scripts..."

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_initial_setup.sh?$(date +%s)" -o bdm/bdm_initial_setup.sh
curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_AP_setup.sh?$(date +%s)" -o bdm/bdm_AP_setup.sh
curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_mediamtx_setup.sh?$(date +%s)" -o bdm/bdm_mediamtx_setup.sh
curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_web_setup.sh?$(date +%s)" -o bdm/bdm_web_setup.sh

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/bdc/bdc_fresh_install_setup.sh?$(date +%s)" -o bdc/bdc_fresh_install_setup.sh

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/mesh/add_mesh_network.sh?$(date +%s)" -o mesh/add_mesh_network.sh

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/device_configure.sh?$(date +%s)" -o common/device_configure.sh
curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/radio_map_setup.sh?$(date +%s)" -o common/radio_map_setup.sh
curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/golden_image_creation.sh?$(date +%s)" -o common/golden_image_creation.sh

echo "[5/12] Script download complete."


echo "[6/12] Installing BirdDog CLI..."

cat << 'EOF' | sudo tee /usr/local/bin/birddog > /dev/null
#!/bin/bash
set -e

ORIG_ARGS=("$@")

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Elevating privileges..."
        exec sudo "$0" "${ORIG_ARGS[@]}"
    fi
}

fetch_scripts() {

echo "Updating BirdDog scripts..."

cd /opt/birddog

curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_initial_setup.sh -o bdm/bdm_initial_setup.sh
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_AP_setup.sh -o bdm/bdm_AP_setup.sh
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_mediamtx_setup.sh -o bdm/bdm_mediamtx_setup.sh
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_web_setup.sh -o bdm/bdm_web_setup.sh

curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/bdc/bdc_fresh_install_setup.sh -o bdc/bdc_fresh_install_setup.sh

curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/mesh/add_mesh_network.sh -o mesh/add_mesh_network.sh

curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/common/device_configure.sh -o common/device_configure.sh
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/common/radio_map_setup.sh -o common/radio_map_setup.sh
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/common/golden_image_creation.sh -o common/golden_image_creation.sh

chmod +x /opt/birddog/common/*.sh
chmod +x /opt/birddog/bdm/*.sh
chmod +x /opt/birddog/bdc/*.sh
chmod +x /opt/birddog/mesh/*.sh

echo "BirdDog update complete."
}

echo ""
echo "================================="
echo "BirdDog CLI"
echo "================================="

case "$1" in

install)
    require_root
    echo "Running BirdDog installer..."
    bash /opt/birddog/common/golden_image_creation.sh
;;

configure)
    require_root
    echo "Running device configuration..."
    bash /opt/birddog/common/device_configure.sh
;;

update)
    require_root
    fetch_scripts
;;

restart)
    require_root
    echo "Restarting BirdDog services..."
    systemctl restart mediamtx 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || true
    systemctl restart birddog-stream 2>/dev/null || true
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

echo "[6/12] BirdDog CLI installed"


echo "[7/12] Setting executable permissions..."

sudo chmod +x /opt/birddog/common/*.sh
sudo chmod +x /opt/birddog/bdm/*.sh
sudo chmod +x /opt/birddog/bdc/*.sh
sudo chmod +x /opt/birddog/mesh/*.sh

echo "[7/12] Permissions applied."


echo "[8/12] Verifying installation..."

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

echo "[8/12] Verification complete."


echo "[9/12] Writing BirdDog version..."

VERSION_DIR="/opt/birddog/version"
VERSION_FILE="$VERSION_DIR/VERSION"

mkdir -p $VERSION_DIR

VERSION="BirdDog_$(date +%Y.%m.%d)_$(git rev-parse --short HEAD 2>/dev/null || echo manual)"

echo "$VERSION" | sudo tee $VERSION_FILE > /dev/null

echo "Version written:"
cat $VERSION_FILE


echo ""
echo "====================================="
echo "BirdDog Golden Image Setup Complete"
echo "====================================="
echo ""

echo "Next step:"
echo ""
echo "Run device configuration with:"
echo ""
echo "   birddog configure"
echo ""
echo "or"
echo ""
echo "   sudo /opt/birddog/common/device_configure.sh"
echo ""
