#!/bin/bash
set -e

echo "====================================="
echo "BirdDog Golden Image Creation"
echo "====================================="
echo ""

# --------------------------------------------------
# INSTALL MODE SELECTION
# --------------------------------------------------

BIRDDOG_MODE="${BIRDDOG_MODE:-}"

if [[ -z "$BIRDDOG_MODE" ]]; then

    echo "Select install mode:"
    echo ""
    echo "[F] Full install   → packages + MediaMTX + scripts"
    echo "[R] Refresh        → scripts only (fast field update)"
    echo ""

    read -p "Enter choice [F/R]: " MODE

    case "$MODE" in
        F|f) BIRDDOG_MODE="full" ;;
        R|r) BIRDDOG_MODE="refresh" ;;
        *) echo "Invalid selection"; exit 1 ;;
    esac
fi

echo ""
echo "Installer mode: $BIRDDOG_MODE"
echo ""

# --------------------------------------------------

BIRDDOG_ROOT=/opt/birddog
VERSION_DIR=$BIRDDOG_ROOT/version
COMMIT_FILE=$VERSION_DIR/COMMIT

mkdir -p $BIRDDOG_ROOT/{bdm,bdc,mesh,common,mediamtx,web,logs,version}

# --------------------------------------------------
# FULL MODE ONLY
# --------------------------------------------------

if [[ "$BIRDDOG_MODE" == "full" ]]; then

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

        if [[ "$MEDIAMTX_MODE" == "latest" ]]; then

            MEDIAMTX_URL=$(curl -fsSL https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
                | grep browser_download_url \
                | grep linux_arm64.tar.gz \
                | cut -d '"' -f 4)

        else

            MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_arm64.tar.gz"

        fi

        echo "Downloading:"
        echo "$MEDIAMTX_URL"

        curl -fL "$MEDIAMTX_URL" -o "$MEDIAMTX_TAR"

        echo "Extracting to staging..."
        rm -rf "$MEDIAMTX_STAGE"
        mkdir -p "$MEDIAMTX_STAGE"

        tar -xzf "$MEDIAMTX_TAR" -C "$MEDIAMTX_STAGE"

        BIN_PATH=$(find "$MEDIAMTX_STAGE" -type f -name mediamtx | head -1)

        if [[ -z "$BIN_PATH" ]]; then
            echo "ERROR: MediaMTX binary not found"
            exit 1
        fi

        rm -rf "$MEDIAMTX_DIR"/*
        mv "$BIN_PATH" "$MEDIAMTX_DIR/mediamtx"
        chmod +x "$MEDIAMTX_DIR/mediamtx"

        rm -rf "$MEDIAMTX_STAGE"
        rm -f "$MEDIAMTX_TAR"

        echo "MediaMTX installed."

    else
        echo "MediaMTX already present — skipping."
    fi

fi

# --------------------------------------------------
# COMMIT CHECK
# --------------------------------------------------

echo "[Phase 2] Commit State Check"

REMOTE_COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)

if [[ -z "$REMOTE_COMMIT" ]]; then
    echo "ERROR: Could not resolve remote commit"
    exit 1
fi

LOCAL_COMMIT="none"
[[ -f $COMMIT_FILE ]] && LOCAL_COMMIT=$(cat $COMMIT_FILE)

echo "Remote commit: $REMOTE_COMMIT"
echo "Local commit : $LOCAL_COMMIT"

# --------------------------------------------------
# SCRIPT FETCH
# --------------------------------------------------

echo "[Phase 3] Script Fetch + Diff Report"

fetch_file() {

REMOTE_PATH="$1"
LOCAL_PATH="$2"

TMP_FILE="/tmp/birddog_fetch.$$"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/$REMOTE_COMMIT/$REMOTE_PATH" -o "$TMP_FILE" || {
    echo "ERROR downloading $REMOTE_PATH"
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
fetch_file common/oobe_reset.sh $BIRDDOG_ROOT/common/oobe_reset.sh
fetch_file common/golden_image_creation.sh $BIRDDOG_ROOT/common/golden_image_creation.sh

echo "$REMOTE_COMMIT" > $COMMIT_FILE

# --------------------------------------------------
# INSTALL LIB
# --------------------------------------------------

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
}

write_version_file() {
TYPE="$1"
cat <<EOV > "$VERSION_DIR/VERSION"
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

# --------------------------------------------------
# PERMISSIONS
# --------------------------------------------------

echo "[Phase 5] Permission Enforcement"

chmod +x $BIRDDOG_ROOT/common/*.sh
chmod +x $BIRDDOG_ROOT/bdm/*.sh
chmod +x $BIRDDOG_ROOT/bdc/*.sh
chmod +x $BIRDDOG_ROOT/mesh/*.sh

# --------------------------------------------------
# CLI INSTALL
# --------------------------------------------------

echo "[Phase 6] Installing / Refreshing BirdDog CLI"

# <<< KEEP YOUR CURRENT WORKING CLI BLOCK HERE >>>

# --------------------------------------------------
# FINAL
# --------------------------------------------------

echo "[Phase 7] Finalization"

write_version_file golden
generate_manifest

echo ""
echo "BirdDog install complete."
echo "Next step: birddog configure"
echo ""
