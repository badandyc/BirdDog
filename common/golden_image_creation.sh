#!/bin/bash
set -e
set -o pipefail

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
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

    echo "[Phase 0] Updating package index"
    apt update || true

    echo ""
    echo "[Phase 1] Package Assurance"

    for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool curl tar iw wireless-tools; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            echo "  OK       $pkg"
        else
            echo "  INSTALL  $pkg"
            apt install -y "$pkg"
        fi
    done

    echo ""
    echo "[Phase 1.5] Installing MediaMTX"

    MEDIAMTX_DIR="$BIRDDOG_ROOT/mediamtx"
    MEDIAMTX_STAGE="/tmp/mediamtx_stage"
    MEDIAMTX_TAR="/tmp/mediamtx.tar.gz"
    MEDIAMTX_VERSION="v1.16.3"

    # Pi 3B is armv7l (32-bit) — must use arm7 build, NOT arm64
    MEDIAMTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_arm7.tar.gz"

    mkdir -p "$MEDIAMTX_DIR"

    if [[ -f "$MEDIAMTX_DIR/mediamtx" ]]; then
        echo "  MediaMTX already present — skipping download"
    else
        echo "  Downloading MediaMTX $MEDIAMTX_VERSION (linux_arm7)..."

        curl --connect-timeout 30 --retry 3 --retry-delay 5 -fL \
            "$MEDIAMTX_URL" -o "$MEDIAMTX_TAR"

        rm -rf "$MEDIAMTX_STAGE"
        mkdir -p "$MEDIAMTX_STAGE"

        tar -xzf "$MEDIAMTX_TAR" -C "$MEDIAMTX_STAGE"

        BIN=$(find "$MEDIAMTX_STAGE" -name mediamtx -type f | head -1)

        if [[ -z "$BIN" ]]; then
            echo "ERROR: MediaMTX binary not found in archive"
            exit 1
        fi

        rm -rf "$MEDIAMTX_DIR"/*
        mv "$BIN" "$MEDIAMTX_DIR/mediamtx"
        chmod +x "$MEDIAMTX_DIR/mediamtx"

        rm -rf "$MEDIAMTX_STAGE"
        rm -f "$MEDIAMTX_TAR"

        echo "  MediaMTX installed at $MEDIAMTX_DIR/mediamtx"
    fi

fi

# --------------------------------------------------
# COMMIT STATE
# --------------------------------------------------

echo ""
echo "[Phase 2] Commit State Check"

REMOTE_COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)

if [[ -z "$REMOTE_COMMIT" ]]; then
    echo "ERROR: Could not resolve remote commit — check network connectivity"
    exit 1
fi

LOCAL_COMMIT="none"
[[ -f "$COMMIT_FILE" ]] && LOCAL_COMMIT=$(cat "$COMMIT_FILE")

echo "  Remote : $REMOTE_COMMIT"
echo "  Local  : $LOCAL_COMMIT"

if [[ "$REMOTE_COMMIT" == "$LOCAL_COMMIT" ]]; then
    echo "  State  : Already at latest commit"
else
    echo "  State  : Advancing $LOCAL_COMMIT → $REMOTE_COMMIT"
fi

# --------------------------------------------------
# FETCH SCRIPTS
# --------------------------------------------------

echo ""
echo "[Phase 3] Fetch Scripts"

FETCH_FAILED=0

fetch_file() {
    local SRC="$1"
    local DEST="$2"
    local TMP="/tmp/birddog_fetch.$$"

    if ! curl --connect-timeout 10 --retry 3 --retry-delay 2 -fsSL \
        "https://raw.githubusercontent.com/badandyc/BirdDog/${REMOTE_COMMIT}/${SRC}" \
        -o "$TMP"; then
        echo "  FAILED   $SRC"
        FETCH_FAILED=1
        rm -f "$TMP"
        return
    fi

    if [[ ! -f "$DEST" ]]; then
        echo "  NEW      $SRC"
        install -m 0755 "$TMP" "$DEST"
    elif cmp -s "$TMP" "$DEST"; then
        echo "  UNCHANGED $SRC"
        rm -f "$TMP"
    else
        echo "  UPDATED  $SRC"
        install -m 0755 "$TMP" "$DEST"
    fi
}

fetch_file common/golden_image_creation.sh  "$BIRDDOG_ROOT/common/golden_image_creation.sh"
fetch_file common/script_update.sh          "$BIRDDOG_ROOT/common/script_update.sh"
fetch_file common/device_configure.sh       "$BIRDDOG_ROOT/common/device_configure.sh"
fetch_file common/radio_map_setup.sh        "$BIRDDOG_ROOT/common/radio_map_setup.sh"
fetch_file common/oobe_reset.sh             "$BIRDDOG_ROOT/common/oobe_reset.sh"
fetch_file common/verify_node.sh            "$BIRDDOG_ROOT/common/verify_node.sh"
fetch_file bdm/bdm_initial_setup.sh         "$BIRDDOG_ROOT/bdm/bdm_initial_setup.sh"
fetch_file bdm/bdm_AP_setup.sh              "$BIRDDOG_ROOT/bdm/bdm_AP_setup.sh"
fetch_file bdm/bdm_mediamtx_setup.sh        "$BIRDDOG_ROOT/bdm/bdm_mediamtx_setup.sh"
fetch_file bdm/bdm_web_setup.sh             "$BIRDDOG_ROOT/bdm/bdm_web_setup.sh"
fetch_file bdc/bdc_fresh_install_setup.sh   "$BIRDDOG_ROOT/bdc/bdc_fresh_install_setup.sh"
fetch_file mesh/add_mesh_network.sh         "$BIRDDOG_ROOT/mesh/add_mesh_network.sh"

if [[ "$FETCH_FAILED" -eq 1 ]]; then
    echo ""
    echo "ERROR: One or more scripts failed to fetch — aborting"
    echo "       Platform identity not updated"
    exit 1
fi

# --------------------------------------------------
# PERMISSIONS
# --------------------------------------------------

echo ""
echo "[Phase 4] Permissions"

chmod +x "$BIRDDOG_ROOT"/common/*.sh
chmod +x "$BIRDDOG_ROOT"/bdm/*.sh
chmod +x "$BIRDDOG_ROOT"/bdc/*.sh
chmod +x "$BIRDDOG_ROOT"/mesh/*.sh

# --------------------------------------------------
# WRITE VERSION IDENTITY
# --------------------------------------------------

echo "$REMOTE_COMMIT"                       > "$COMMIT_FILE"
echo "commit-$REMOTE_COMMIT"                > "$VERSION_FILE"
date -u +"%Y-%m-%dT%H:%M:%SZ"              > "$BUILD_FILE"

echo ""
echo "[Phase 5] Installing BirdDog CLI"

cat > /usr/local/bin/birddog << 'BIRDDOG_CLI'
#!/bin/bash
set -e

BIRDDOG_ROOT="/opt/birddog"

show_help() {
echo ""
echo "================================="
echo "         BirdDog CLI"
echo "================================="
echo ""
echo "System:"
echo "  birddog install      Full or refresh golden image"
echo "  birddog update       Fetch latest scripts from repo"
echo "  birddog configure    Configure node role (BDC / BDM)"
echo "  birddog reset        Wipe node config (OOBE)"
echo ""
echo "Verification:"
echo "  birddog verify       Full node health check"
echo "  birddog status       Platform version + commit state"
echo "  birddog radios       Show current radio layout"
echo ""
echo "Operations:"
echo "  birddog restart      Restart BirdDog services"
echo ""
echo "================================="
echo ""
}

case "$1" in

install)
    sudo bash "$BIRDDOG_ROOT/common/golden_image_creation.sh"
    ;;

update)
    sudo bash "$BIRDDOG_ROOT/common/script_update.sh"
    ;;

configure)
    sudo bash "$BIRDDOG_ROOT/common/device_configure.sh"
    ;;

reset)
    sudo bash "$BIRDDOG_ROOT/common/oobe_reset.sh"
    ;;

verify)
    sudo bash "$BIRDDOG_ROOT/common/verify_node.sh"
    ;;

status)
    echo ""
    echo "Version : $(cat $BIRDDOG_ROOT/version/VERSION 2>/dev/null || echo unknown)"
    echo "Commit  : $(cat $BIRDDOG_ROOT/version/COMMIT  2>/dev/null || echo unknown)"
    echo "Built   : $(cat $BIRDDOG_ROOT/version/BUILD   2>/dev/null || echo unknown)"
    echo ""
    REMOTE=$(git ls-remote https://github.com/badandyc/BirdDog HEAD 2>/dev/null | cut -c1-7 || echo "unreachable")
    LOCAL=$(cat $BIRDDOG_ROOT/version/COMMIT 2>/dev/null || echo none)
    if [[ "$REMOTE" == "$LOCAL" ]]; then
        echo "Repo    : up to date ($LOCAL)"
    else
        echo "Repo    : update available ($LOCAL → $REMOTE)"
    fi
    echo ""
    ;;

radios)
    echo ""
    echo "Radio layout:"
    for IF in wlan0 wlan1 wlan2; do
        if ip link show "$IF" >/dev/null 2>&1; then
            DRIVER=$(ethtool -i "$IF" 2>/dev/null | awk '/driver:/{print $2}')
            MODE=$(iw dev "$IF" info 2>/dev/null | awk '/type/{print $2}')
            STATE=$(ip link show "$IF" | awk '/state/{print $9}')
            echo "  $IF  driver=$DRIVER  mode=$MODE  state=$STATE"
        else
            echo "  $IF  not present"
        fi
    done
    echo ""
    ;;

restart)
    echo "Restarting BirdDog services..."
    sudo systemctl restart birddog-mesh.service  2>/dev/null && echo "  birddog-mesh  restarted" || echo "  birddog-mesh  not installed"
    sudo systemctl restart mediamtx.service      2>/dev/null && echo "  mediamtx      restarted" || echo "  mediamtx      not installed"
    sudo systemctl restart birddog-stream.service 2>/dev/null && echo "  birddog-stream restarted" || echo "  birddog-stream not installed"
    sudo systemctl restart nginx.service         2>/dev/null && echo "  nginx         restarted" || echo "  nginx         not installed"
    echo ""
    ;;

*)
    show_help
    ;;

esac
BIRDDOG_CLI

chmod +x /usr/local/bin/birddog

# --------------------------------------------------

echo ""
echo "[Phase 6] Finalization"
echo ""
echo "====================================="
echo "Golden image creation complete"
echo "  Commit : $REMOTE_COMMIT"
echo "  Mode   : $BIRDDOG_MODE"
echo "====================================="
echo ""
echo "Next step: birddog configure"
echo ""
