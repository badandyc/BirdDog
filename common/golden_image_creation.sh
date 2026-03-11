#!/bin/bash
set -e

echo "=== BirdDog Golden Image Creation ==="

echo "[1/13] Installing required packages..."

sudo apt update

for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool; do
    dpkg -s "$pkg" >/dev/null 2>&1 || sudo apt install -y "$pkg"
done

echo "[1/13] Package check complete."


echo "[2/13] Creating BirdDog directory structure..."

sudo mkdir -p /opt/birddog/{bdm,bdc,mesh,common,mediamtx,web,version,logs}
sudo chmod -R 777 /opt/birddog

echo "[2/13] Directory structure ready."


echo "[3/13] Installing install_lib framework..."

cat << 'EOF' | sudo tee /opt/birddog/common/install_lib.sh > /dev/null
#!/bin/bash

BIRDDOG_ROOT="/opt/birddog"
LOG_DIR="$BIRDDOG_ROOT/logs"
VERSION_DIR="$BIRDDOG_ROOT/version"

mkdir -p "$LOG_DIR"
mkdir -p "$VERSION_DIR"

start_install_log() {
    TYPE="$1"
    LOGFILE="$LOG_DIR/${TYPE}_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "$LOGFILE") 2>&1
    echo "=== BirdDog Install Session ==="
    echo "Type: $TYPE"
    echo "Time: $(date)"
}

write_version_file() {
    TYPE="$1"
    VERSION_FILE="$VERSION_DIR/VERSION"

    BUILD_TIME=$(date -Iseconds)
    COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD 2>/dev/null | cut -c1-7)

    [[ -z "$COMMIT" ]] && COMMIT="unknown"

    cat <<EOV > "$VERSION_FILE"
BUILD_TIME=$BUILD_TIME
GIT_COMMIT=$COMMIT
INSTALL_TYPE=$TYPE
EOV

    echo "Version updated."
}

generate_manifest() {
    MANIFEST_FILE="$VERSION_DIR/MANIFEST"
    find "$BIRDDOG_ROOT" -name "*.sh" -exec sha256sum {} \; | sort > "$MANIFEST_FILE"
    echo "Manifest generated."
}
EOF

sudo chmod +x /opt/birddog/common/install_lib.sh

source /opt/birddog/common/install_lib.sh
start_install_log golden

echo "[3/13] install_lib ready."


echo "[4/13] Fetching BirdDog scripts..."

cd /opt/birddog

fetch() {
curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/$1?$(date +%s)" -o "$2"
}

fetch bdm/bdm_initial_setup.sh bdm/bdm_initial_setup.sh
fetch bdm/bdm_AP_setup.sh bdm/bdm_AP_setup.sh
fetch bdm/bdm_mediamtx_setup.sh bdm/bdm_mediamtx_setup.sh
fetch bdm/bdm_web_setup.sh bdm/bdm_web_setup.sh

fetch bdc/bdc_fresh_install_setup.sh bdc/bdc_fresh_install_setup.sh

fetch mesh/add_mesh_network.sh mesh/add_mesh_network.sh

fetch common/device_configure.sh common/device_configure.sh
fetch common/radio_map_setup.sh common/radio_map_setup.sh
fetch common/golden_image_creation.sh common/golden_image_creation.sh

echo "[4/13] Script fetch complete."


echo "[5/13] Setting executable permissions..."

sudo chmod +x /opt/birddog/common/*.sh
sudo chmod +x /opt/birddog/bdm/*.sh
sudo chmod +x /opt/birddog/bdc/*.sh
sudo chmod +x /opt/birddog/mesh/*.sh

echo "[5/13] Permissions set."


echo "[6/13] Installing / Updating BirdDog CLI..."

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

source /opt/birddog/common/install_lib.sh 2>/dev/null || true

fetch_scripts() {

start_install_log update

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

write_version_file update
generate_manifest

echo "BirdDog update complete."
}

echo ""
echo "================================="
echo "BirdDog CLI"
echo "================================="

case "$1" in

install)
require_root
bash /opt/birddog/common/golden_image_creation.sh
;;

configure)
require_root
start_install_log configure
bash /opt/birddog/common/device_configure.sh
write_version_file configure
generate_manifest
;;

update)
require_root
fetch_scripts
;;

status)
echo ""
echo "Version:"
cat /opt/birddog/version/VERSION 2>/dev/null || echo "Unknown"
echo ""
mesh status 2>/dev/null || echo "Mesh not configured"
;;

*)
echo "Unknown command"
;;

esac
EOF

sudo chmod +x /usr/local/bin/birddog

echo "[6/13] CLI ready."


echo "[7/13] Generating version + manifest..."

write_version_file golden
generate_manifest

echo "[7/13] Versioning complete."


echo "[8/13] Verification..."

ls -R /opt/birddog | head -40

echo ""
echo "====================================="
echo "BirdDog Golden Image Setup Complete"
echo "====================================="
echo ""
echo "Next step:"
echo "   birddog configure"
echo ""
