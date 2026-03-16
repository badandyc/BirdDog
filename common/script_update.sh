#!/bin/bash
set -o pipefail

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

BIRDDOG_ROOT="/opt/birddog"
mkdir -p "$BIRDDOG_ROOT/logs"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG="$BIRDDOG_ROOT/logs/script_update_${TIMESTAMP}.log"
exec > >(tee -a "$LOG") 2>&1

echo "====================================="
echo "BirdDog Script Update"
echo "====================================="
echo ""

VERSION_DIR="$BIRDDOG_ROOT/version"
COMMIT_FILE="$VERSION_DIR/COMMIT"
VERSION_FILE="$VERSION_DIR/VERSION"
BUILD_FILE="$VERSION_DIR/BUILD"

mkdir -p "$BIRDDOG_ROOT"/{bdm,bdc,mesh,common,mediamtx,web,logs,version}

echo "[Update] Resolving repository state"

REMOTE_COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)

if [[ -z "$REMOTE_COMMIT" ]]; then
    echo "ERROR: Could not resolve remote commit — check network connectivity"
    exit 1
fi

if ! [[ "$REMOTE_COMMIT" =~ ^[0-9a-f]{7}$ ]]; then
    echo "ERROR: Invalid commit format: $REMOTE_COMMIT"
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

echo ""
echo "[Update] Fetching scripts"

FETCH_FAILED=0
SELF_UPDATED=0
REBOOT_NEEDED=0

REBOOT_SCRIPTS=(
    "common/golden_image_creation.sh"
    "common/device_configure.sh"
    "bdm/bdm_AP_setup.sh"
    "bdm/bdm_mediamtx_setup.sh"
    "bdm/bdm_web_setup.sh"
    "bdc/bdc_fresh_install_setup.sh"
    "mesh/add_mesh_network.sh"
)

fetch_file() {
    local SRC="$1"
    local DEST="$2"
    local TMP="/tmp/birddog_fetch.$$"

    if ! curl --connect-timeout 10 --retry 3 --retry-delay 2 -fsSL \
        "https://raw.githubusercontent.com/badandyc/BirdDog/${REMOTE_COMMIT}/${SRC}" \
        -o "$TMP" 2>/dev/null; then
        echo "  FAILED    $SRC"
        FETCH_FAILED=1
        rm -f "$TMP"
        return 0
    fi

    if [[ "$SRC" == "common/script_update.sh" ]]; then
        if cmp -s "$TMP" "$DEST" 2>/dev/null; then
            echo "  UNCHANGED $SRC"
            rm -f "$TMP"
        else
            echo "  STAGED    $SRC  (will activate after fetch completes)"
            install -m 0755 "$TMP" "${DEST}.new" || true
            SELF_UPDATED=1
        fi
        return 0
    fi

    if [[ ! -f "$DEST" ]]; then
        echo "  NEW       $SRC"
        install -m 0755 "$TMP" "$DEST" || true
        for RS in "${REBOOT_SCRIPTS[@]}"; do
            [[ "$SRC" == "$RS" ]] && REBOOT_NEEDED=1
        done
    elif cmp -s "$TMP" "$DEST"; then
        echo "  UNCHANGED $SRC"
        rm -f "$TMP"
    else
        echo "  UPDATED   $SRC"
        install -m 0755 "$TMP" "$DEST" || true
        for RS in "${REBOOT_SCRIPTS[@]}"; do
            [[ "$SRC" == "$RS" ]] && REBOOT_NEEDED=1
        done
    fi

    return 0
}

fetch_file common/script_update.sh          "$BIRDDOG_ROOT/common/script_update.sh"
fetch_file common/golden_image_creation.sh  "$BIRDDOG_ROOT/common/golden_image_creation.sh"
fetch_file common/device_configure.sh       "$BIRDDOG_ROOT/common/device_configure.sh"
fetch_file common/oobe_reset.sh             "$BIRDDOG_ROOT/common/oobe_reset.sh"
fetch_file common/verify_node.sh            "$BIRDDOG_ROOT/common/verify_node.sh"
fetch_file bdm/bdm_AP_setup.sh              "$BIRDDOG_ROOT/bdm/bdm_AP_setup.sh"
fetch_file bdm/bdm_mediamtx_setup.sh        "$BIRDDOG_ROOT/bdm/bdm_mediamtx_setup.sh"
fetch_file bdm/bdm_web_setup.sh             "$BIRDDOG_ROOT/bdm/bdm_web_setup.sh"
fetch_file bdc/bdc_fresh_install_setup.sh   "$BIRDDOG_ROOT/bdc/bdc_fresh_install_setup.sh"
fetch_file mesh/add_mesh_network.sh         "$BIRDDOG_ROOT/mesh/add_mesh_network.sh"

if [[ "$FETCH_FAILED" -eq 1 ]]; then
    echo ""
    echo "ERROR: One or more scripts failed to fetch"
    echo "       Platform identity not updated"
    rm -f "$BIRDDOG_ROOT/common/script_update.sh.new"
    exit 1
fi

echo ""
echo "[Update] Setting permissions"

chmod +x "$BIRDDOG_ROOT"/common/*.sh || true
chmod +x "$BIRDDOG_ROOT"/bdm/*.sh    || true
chmod +x "$BIRDDOG_ROOT"/bdc/*.sh    || true
chmod +x "$BIRDDOG_ROOT"/mesh/*.sh   || true

if [[ "$SELF_UPDATED" -eq 1 ]]; then
    echo "[Update] Activating new updater"
    mv -f "$BIRDDOG_ROOT/common/script_update.sh.new" \
          "$BIRDDOG_ROOT/common/script_update.sh"
    chmod +x "$BIRDDOG_ROOT/common/script_update.sh"
fi

echo "$REMOTE_COMMIT"              > "$COMMIT_FILE"
echo "commit-$REMOTE_COMMIT"       > "$VERSION_FILE"
date -u +"%Y-%m-%dT%H:%M:%SZ"     > "$BUILD_FILE"

echo ""
echo "====================================="
echo "BirdDog update complete"
echo "  Commit : $REMOTE_COMMIT"
if [[ "$REBOOT_NEEDED" -eq 1 ]]; then
    echo "  ⚠  Reboot recommended"
fi
echo "====================================="
echo ""
if [[ "$REBOOT_NEEDED" -eq 1 ]]; then
    echo "  Service scripts were updated — reboot to apply."
    echo "     sudo reboot"
    echo ""
fi
echo "Update log: $LOG"
echo ""
