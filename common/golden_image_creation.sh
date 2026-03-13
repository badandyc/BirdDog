#!/bin/bash
set -e
set -o pipefail

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -E bash /opt/birddog/common/golden_image_creation.sh "$@"
fi

echo "====================================="
echo "BirdDog Golden Image Creation"
echo "====================================="
echo ""

# --------------------------------------------------
# INSTALL MODE
# --------------------------------------------------

if [[ -z "$BIRDDOG_MODE" ]]; then
    echo "Select install mode:"
    echo ""
    echo "[F] Full install"
    echo "[R] Refresh (scripts only)"
    echo ""
    read -r -p "Choice: " MODE

    case "$MODE" in
        F|f) BIRDDOG_MODE="full" ;;
        R|r) BIRDDOG_MODE="refresh" ;;
        *) echo "Invalid selection"; exit 1 ;;
    esac
fi

echo "Mode: $BIRDDOG_MODE"
echo ""

BIRDDOG_ROOT="/opt/birddog"
VERSION_DIR="$BIRDDOG_ROOT/version"
COMMIT_FILE="$VERSION_DIR/COMMIT"
VERSION_FILE="$VERSION_DIR/VERSION"
BUILD_FILE="$VERSION_DIR/BUILD"

mkdir -p "$BIRDDOG_ROOT"/{bdm,bdc,mesh,common,mediamtx,web,logs,version}

# --------------------------------------------------
# FULL INSTALL ONLY
# --------------------------------------------------

if [[ "$BIRDDOG_MODE" == "full" ]]; then

    echo "[Phase 0] Updating package index (best effort)"
    apt update || true

    echo "[Phase 1] Package Assurance"

    for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool curl tar; do
        dpkg -s "$pkg" >/dev/null 2>&1 || apt install -y "$pkg"
    done

    echo "[Phase 1.5] Installing MediaMTX"

    MEDIAMTX_DIR="$BIRDDOG_ROOT/mediamtx"
    MEDIAMTX_STAGE="/tmp/mediamtx_stage"
    MEDIAMTX_TAR="/tmp/mediamtx.tar.gz"
    MEDIAMTX_VERSION="v1.16.3"

    mkdir -p "$MEDIAMTX_DIR"

    if [[ ! -f "$MEDIAMTX_DIR/mediamtx" ]]; then

        URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_arm64.tar.gz"

        curl -fL "$URL" -o "$MEDIAMTX_TAR"

        rm -rf "$MEDIAMTX_STAGE"
        mkdir -p "$MEDIAMTX_STAGE"

        tar -xzf "$MEDIAMTX_TAR" -C "$MEDIAMTX_STAGE"

        BIN=$(find "$MEDIAMTX_STAGE" -name mediamtx | head -1)

        if [[ -z "$BIN" ]]; then
            echo "ERROR MediaMTX binary missing"
            exit 1
        fi

        rm -rf "$MEDIAMTX_DIR"/*
        mv "$BIN" "$MEDIAMTX_DIR/mediamtx"
        chmod +x "$MEDIAMTX_DIR/mediamtx"

        rm -rf "$MEDIAMTX_STAGE"
        rm -f "$MEDIAMTX_TAR"

    fi

fi

# --------------------------------------------------
# COMMIT
# --------------------------------------------------

echo "[Phase 2] Commit State Check"

REMOTE_COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)

if [[ -z "$REMOTE_COMMIT" ]]; then
    echo "ERROR resolving commit"
    exit 1
fi

LOCAL_COMMIT="none"
[[ -f "$COMMIT_FILE" ]] && LOCAL_COMMIT=$(cat "$COMMIT_FILE")

echo "Remote: $REMOTE_COMMIT"
echo "Local : $LOCAL_COMMIT"

if [[ "$REMOTE_COMMIT" == "$LOCAL_COMMIT" ]]; then
    echo "State : Installer already aligned with platform commit"
else
    echo "State : Installer newer than node platform state"
    echo "        $LOCAL_COMMIT → $REMOTE_COMMIT"
fi

echo ""

# --------------------------------------------------
# FETCH
# --------------------------------------------------

echo "[Phase 3] Fetch Scripts"

fetch_file() {

    TMP="/tmp/birddog_fetch.$$"

    curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/$REMOTE_COMMIT/$1" -o "$TMP" || exit 1

    if [[ ! -f "$2" ]]; then
        echo "NEW $1"
        install -m 0755 "$TMP" "$2"
        return
    fi

    if cmp -s "$TMP" "$2"; then
        echo "UNCHANGED $1"
        rm -f "$TMP"
    else
        echo "UPDATED $1"
        install -m 0755 "$TMP" "$2"
    fi
}

fetch_file bdm/bdm_initial_setup.sh "$BIRDDOG_ROOT/bdm/bdm_initial_setup.sh"
fetch_file bdm/bdm_AP_setup.sh "$BIRDDOG_ROOT/bdm/bdm_AP_setup.sh"
fetch_file bdm/bdm_mediamtx_setup.sh "$BIRDDOG_ROOT/bdm/bdm_mediamtx_setup.sh"
fetch_file bdm/bdm_web_setup.sh "$BIRDDOG_ROOT/bdm/bdm_web_setup.sh"
fetch_file bdc/bdc_fresh_install_setup.sh "$BIRDDOG_ROOT/bdc/bdc_fresh_install_setup.sh"
fetch_file mesh/add_mesh_network.sh "$BIRDDOG_ROOT/mesh/add_mesh_network.sh"
fetch_file common/device_configure.sh "$BIRDDOG_ROOT/common/device_configure.sh"
fetch_file common/radio_map_setup.sh "$BIRDDOG_ROOT/common/radio_map_setup.sh"
fetch_file common/oobe_reset.sh "$BIRDDOG_ROOT/common/oobe_reset.sh"
fetch_file common/script_update.sh "$BIRDDOG_ROOT/common/script_update.sh"

echo "$REMOTE_COMMIT" > "$COMMIT_FILE"
echo "commit-$REMOTE_COMMIT" > "$VERSION_FILE"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$BUILD_FILE"

# --------------------------------------------------
# PERMS
# --------------------------------------------------

echo "[Phase 4] Permissions"

chmod +x "$BIRDDOG_ROOT"/common/*.sh
chmod +x "$BIRDDOG_ROOT"/bdm/*.sh
chmod +x "$BIRDDOG_ROOT"/bdc/*.sh
chmod +x "$BIRDDOG_ROOT"/mesh/*.sh

# --------------------------------------------------

echo "[Phase 5] Finalization"
echo "Golden install complete."
echo ""
