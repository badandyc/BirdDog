#!/bin/bash
set -e

echo "=== BirdDog Golden Image Creation ==="

BIRDDOG_ROOT=/opt/birddog
VERSION_DIR=$BIRDDOG_ROOT/version
COMMIT_FILE=$VERSION_DIR/COMMIT

mkdir -p $BIRDDOG_ROOT/{bdm,bdc,mesh,common,mediamtx,web,logs,version}

echo "[Phase 0] Updating package index (best effort)"
sudo apt update || echo "apt update failed — continuing"

echo "[Phase 1] Package Assurance"

for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool curl tar; do
dpkg -s "$pkg" >/dev/null 2>&1 || sudo apt install -y "$pkg"
done

echo "Packages ready."

echo "[Phase 1.5] Installing MediaMTX binary"

MEDIAMTX_DIR="/opt/birddog/mediamtx"
MEDIAMTX_TAR="/tmp/mediamtx.tar.gz"
MEDIAMTX_STAGE="/tmp/mediamtx_stage"

MEDIAMTX_MODE="${MEDIAMTX_MODE:-pinned}"
MEDIAMTX_VERSION="v1.16.3"

mkdir -p "$MEDIAMTX_DIR"

if [ ! -f "$MEDIAMTX_DIR/mediamtx" ]; then

    echo "MediaMTX mode: $MEDIAMTX_MODE"

    if [[ "$MEDIAMTX_MODE" == "latest" ]]; then

        echo "Resolving latest MediaMTX release..."

        MEDIAMTX_URL=$(curl -fsSL https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
            | grep browser_download_url \
            | grep linux_arm64.tar.gz \
            | cut -d '"' -f 4)

        if [[ -z "$MEDIAMTX_URL" ]]; then
            echo "ERROR: Could not resolve latest MediaMTX URL"
            exit 1
        fi

    else

        echo "Using pinned MediaMTX version: $MEDIAMTX_VERSION"

        MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_arm64.tar.gz"

    fi

    echo "Downloading:"
    echo "$MEDIAMTX_URL"

    curl -fL "$MEDIAMTX_URL" -o "$MEDIAMTX_TAR"

    if [ ! -s "$MEDIAMTX_TAR" ]; then
        echo "ERROR: MediaMTX download failed (empty file)"
        exit 1
    fi

    if ! file "$MEDIAMTX_TAR" | grep -q gzip; then
        echo "ERROR: Downloaded MediaMTX archive is not valid gzip"
        exit 1
    fi

    echo "Extracting to staging..."
    rm -rf "$MEDIAMTX_STAGE"
    mkdir -p "$MEDIAMTX_STAGE"

    tar -xzf "$MEDIAMTX_TAR" -C "$MEDIAMTX_STAGE"

    BIN_PATH=$(find "$MEDIAMTX_STAGE" -type f -name mediamtx | head -1)

    if [[ -z "$BIN_PATH" ]]; then
        echo "ERROR: MediaMTX binary not found after extraction"
        exit 1
    fi

    echo "Installing MediaMTX binary..."
    rm -rf "$MEDIAMTX_DIR"/*
    mv "$BIN_PATH" "$MEDIAMTX_DIR/mediamtx"
    chmod +x "$MEDIAMTX_DIR/mediamtx"

    rm -rf "$MEDIAMTX_STAGE"
    rm -f "$MEDIAMTX_TAR"

    echo "MediaMTX installed successfully."

else
    echo "MediaMTX already present — skipping install."
fi

echo "[Phase 2] Commit State Check"

REMOTE_COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)

if [[ -z "$REMOTE_COMMIT" ]]; then
    echo "ERROR: Could not resolve remote commit"
    exit 1
fi

LOCAL_COMMIT="none"
[[ -f $COMMIT_FILE ]] && LOCAL_COMMIT=$(cat $COMMIT_FILE)

PREVIOUS_COMMIT=$LOCAL_COMMIT
NEW_COMMIT=$REMOTE_COMMIT

echo "Remote commit: $REMOTE_COMMIT"
echo "Local commit : $LOCAL_COMMIT"

echo ""
echo "-------------------------------------"
echo "BirdDog Update Transaction"
echo "FROM commit: $PREVIOUS_COMMIT"
echo "TO   commit: $NEW_COMMIT"
echo "-------------------------------------"
echo ""


echo "[Phase 3] Script Fetch + Diff Report"

fetch_file() {

REMOTE_PATH="$1"
LOCAL_PATH="$2"

TMP_FILE="/tmp/birddog_fetch.$$"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/$REMOTE_COMMIT/$REMOTE_PATH" -o "$TMP_FILE" || {
    echo "ERROR: failed downloading $REMOTE_PATH"
    exit 1
}

if [[ ! -f "$LOCAL_PATH" ]]; then
echo "NEW       $REMOTE_PATH"
mv "$TMP_FILE" "$LOCAL_PATH"
return
fi

REMOTE_SUM=$(sha256sum "$TMP_FILE" | awk '{print $1}')
LOCAL_SUM=$(sha256sum "$LOCAL_PATH" | awk '{print $1}')

if [[ "$REMOTE_SUM" == "$LOCAL_SUM" ]]; then
echo "UNCHANGED $REMOTE_PATH"
rm "$TMP_FILE"
else
echo "UPDATED   $REMOTE_PATH"
mv "$TMP_FILE" "$LOCAL_PATH"
fi
}

fetch_file bdm/bdm_initial_setup.sh $BIRDDOG_ROOT/bdm/bdm_initial_setup.sh
fetch_file bdm/bdm_AP_setup.sh $BIRDDOG_ROOT/bdm/bdm_AP_setup.sh
fetch_file bdm/bdm_mediamtx_setup.sh $BIRDDOG_ROOT/bdm/bdm_mediamtx_setup.sh
fetch_file bdm/bdm_web_setup.sh $BIRDDOG_ROOT/bdm/bdm_web_setup.sh

fetch_file bdc/bdc_fresh_install_setup.sh $BIRDDOG_ROOT/bdc/bdc_fresh_install_setup.sh

fetch_file mesh/add_mesh_network.sh $BIRDDOG_ROOT/mesh/add_mesh_network.sh

fetch_file common/device_configure.sh $BIRDDOG_ROOT/common/device_configure.sh
fetch_file common/radio_map_setup.sh $BIRDDOG_ROOT/common/radio_map_setup.sh
fetch_file common/golden_image_creation.sh $BIRDDOG_ROOT/common/golden_image_creation.sh
fetch_file common/oobe_reset.sh $BIRDDOG_ROOT/common/oobe_reset.sh

echo "$REMOTE_COMMIT" > $COMMIT_FILE


echo "[Phase 4] Install Library"

cat << 'EOF' > $BIRDDOG_ROOT/common/install_lib.sh
#!/bin/bash

BIRDDOG_ROOT="/opt/birddog"
LOG_DIR="$BIRDDOG_ROOT/logs"
VERSION_DIR="$BIRDDOG_ROOT/version"

mkdir -p "$LOG_DIR" "$VERSION_DIR"

start_install_log() {
TYPE="$1"
LOGFILE="$LOG_DIR/${TYPE}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "BirdDog Install Session: $TYPE"
echo "Time: $(date)"
}

write_version_file() {
TYPE="$1"
VERSION_FILE="$VERSION_DIR/VERSION"

cat <<EOV > "$VERSION_FILE"
INSTALL_TIME=$(date -Iseconds)
INSTALL_TYPE=$TYPE
COMMIT=$(cat $VERSION_DIR/COMMIT)
EOV
}

generate_manifest() {
find "$BIRDDOG_ROOT" -type f -name "*.sh" | sort | while read f
do
sha256sum "$f"
done > "$VERSION_DIR/MANIFEST"
}
EOF

chmod +x $BIRDDOG_ROOT/common/install_lib.sh

source $BIRDDOG_ROOT/common/install_lib.sh
start_install_log golden


echo "[Phase 5] Permission Enforcement"

chmod +x $BIRDDOG_ROOT/common/*.sh
chmod +x $BIRDDOG_ROOT/bdm/*.sh
chmod +x $BIRDDOG_ROOT/bdc/*.sh
chmod +x $BIRDDOG_ROOT/mesh/*.sh


echo "[Phase 6] Installing / Refreshing BirdDog CLI"

cat << 'EOF' > /usr/local/bin/birddog
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

show_radios() {

echo ""
echo "================================="
echo "BirdDog Radio Layout"
echo "================================="

printf "%-6s %-8s %-6s %-8s %-6s\n" "IFACE" "TYPE" "CHAN" "TXPWR" "ROLE"

for IF in wlan2 wlan1 wlan0
do
    if ip link show $IF >/dev/null 2>&1; then

        TYPE=$(iw dev $IF info 2>/dev/null | awk '/type/ {print $2}')
        CHAN=$(iw dev $IF info 2>/dev/null | awk '/channel/ {print $2}')
        TX=$(iw dev $IF info 2>/dev/null | awk '/txpower/ {print int($2)"dBm"}')

        ROLE="-"

        if [[ "$IF" == "wlan2" ]]; then ROLE="AP"; fi
        if [[ "$IF" == "wlan1" ]]; then ROLE="MESH"; fi
        if [[ "$IF" == "wlan0" ]]; then ROLE="MGMT"; fi

        printf "%-6s %-8s %-6s %-8s %-6s\n" "$IF" "${TYPE:-?}" "${CHAN:--}" "${TX:-?}" "$ROLE"
    fi
done

echo ""
}

update_scripts() {

REMOTE=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)
LOCAL=$(cat /opt/birddog/version/COMMIT 2>/dev/null || echo none)

echo "Remote commit: $REMOTE"
echo "Local commit : $LOCAL"

if [[ "$REMOTE" == "$LOCAL" ]]; then
    echo "Already up-to-date."
    exit 0
fi

start_install_log update

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/$REMOTE/common/golden_image_creation.sh" \
-o /opt/birddog/common/golden_image_creation.sh

bash /opt/birddog/common/golden_image_creation.sh
}

verify_install() {

echo ""
echo "================================="
echo "BirdDog Verification"
echo "================================="

if sha256sum -c /opt/birddog/version/MANIFEST >/dev/null 2>&1; then
    echo "Script integrity : OK"
else
    echo "Script integrity : FAILED"
fi

if systemctl is-active birddog-mesh.service >/dev/null 2>&1; then
    echo "Mesh service     : OK"
else
    echo "Mesh service     : DOWN"
fi

echo ""
}

case "$1" in

radios)
show_radios
;;

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
update_scripts
;;

verify)
verify_install
;;

verify-node)
bash /opt/birddog/common/verify_node.sh
;;

restart)
require_root
systemctl restart mediamtx 2>/dev/null || true
systemctl restart nginx 2>/dev/null || true
systemctl restart birddog-stream 2>/dev/null || true
;;

status)
cat /opt/birddog/version/VERSION 2>/dev/null || echo "Unknown"
;;

*)
echo "Commands:"
echo " birddog radios"
echo " birddog install"
echo " birddog configure"
echo " birddog update"
echo " birddog verify"
echo " birddog verify-node"
echo " birddog restart"
echo " birddog status"
;;
esac
EOF

chmod +x /usr/local/bin/birddog

echo "[Phase 7] Finalization"

write_version_file golden
generate_manifest

echo ""
echo "BirdDog Commit State:"
echo "Previous: $PREVIOUS_COMMIT"
echo "Current : $(cat $COMMIT_FILE)"
echo ""

echo ""
echo "====================================="
echo "BirdDog Golden Image Setup Complete"
echo "====================================="
echo ""
echo "Next step: birddog configure"
echo ""
