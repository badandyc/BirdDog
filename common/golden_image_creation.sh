#!/bin/bash
set -e

echo "=== BirdDog Golden Image Creation ==="

BIRDDOG_ROOT=/opt/birddog
VERSION_DIR=$BIRDDOG_ROOT/version
COMMIT_FILE=$VERSION_DIR/COMMIT

mkdir -p $BIRDDOG_ROOT/{bdm,bdc,mesh,common,mediamtx,web,logs,version}

echo "[Phase 0] Updating package index"
sudo apt update

echo "[Phase 1] Package Assurance"

for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool curl tar; do
dpkg -s "$pkg" >/dev/null 2>&1 || sudo apt install -y "$pkg"
done

echo "Packages ready."

echo "[Phase 1.5] Installing MediaMTX binary"

MEDIAMTX_DIR="$BIRDDOG_ROOT/mediamtx"
MEDIAMTX_BIN="$MEDIAMTX_DIR/mediamtx"

if [ ! -f "$MEDIAMTX_BIN" ]; then

echo "Downloading MediaMTX..."

TMP="/tmp/mediamtx.tar.gz"

curl -L https://github.com/bluenviron/mediamtx/releases/latest/download/mediamtx_linux_armv7.tar.gz -o "$TMP"

tar -xzf "$TMP" -C /tmp

mv /tmp/mediamtx "$MEDIAMTX_BIN"

chmod +x "$MEDIAMTX_BIN"

rm -rf /tmp/mediamtx*
rm -f "$TMP"

echo "MediaMTX installed."

else
echo "MediaMTX already present."
fi

echo "[Phase 2] Commit State Check"

REMOTE_COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)
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

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/$REMOTE_COMMIT/$REMOTE_PATH" -o "$TMP_FILE"

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
LOGFILE="$LOG_DIR/${TYPE}*$(date +%Y%m%d*%H%M%S).log"
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

# (CLI section unchanged from your current working version)

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
