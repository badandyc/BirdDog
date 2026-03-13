#!/bin/bash
set -e
set -o pipefail

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

echo "====================================="
echo "BirdDog Script Update"
echo "====================================="
echo ""

BIRDDOG_ROOT="/opt/birddog"
VERSION_DIR="$BIRDDOG_ROOT/version"
COMMIT_FILE="$VERSION_DIR/COMMIT"
VERSION_FILE="$VERSION_DIR/VERSION"
BUILD_FILE="$VERSION_DIR/BUILD"

mkdir -p "$BIRDDOG_ROOT"/{bdm,bdc,mesh,common,mediamtx,web,logs,version}

# --------------------------------------------------
# COMMIT STATE
# --------------------------------------------------

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

# --------------------------------------------------
# FETCH SCRIPTS
# --------------------------------------------------

echo "[Update] Fetching scripts"

FETCH_FAILED=0
SELF_UPDATED=0

fetch_file() {
    local SRC="$1"
    local DEST="$2"
    local TMP="/tmp/birddog_fetch.$$"

    if ! curl --connect-timeout 10 --retry 3 --retry-delay 2 -fsSL \
        "https://raw.githubusercontent.com/badandyc/BirdDog/${REMOTE_COMMIT}/${SRC}" \
        -o "$TMP"; then
        echo "  FAILED    $SRC"
        FETCH_FAILED=1
        rm -f "$TMP"
        return
    fi

    # Self-updater: stage alongside current, activate atomically after all
    # other fetches succeed — avoids running a half-written version of ourselves
    if [[ "$SRC" == "common/script_update.sh" ]]; then
        if cmp -s "$TMP" "$DEST" 2>/dev/null; then
            echo "  UNCHANGED $SRC"
            rm -f "$TMP"
        else
            echo "  STAGED    $SRC  (will activate after fetch completes)"
            install -m 0755 "$TMP" "${DEST}.new"
            SELF_UPDATED=1
        fi
        return
    fi

    if [[ ! -f "$DEST" ]]; then
        echo "  NEW       $SRC"
        install -m 0755 "$TMP" "$DEST"
    elif cmp -s "$TMP" "$DEST"; then
        echo "  UNCHANGED $SRC"
        rm -f "$TMP"
    else
        echo "  UPDATED   $SRC"
        install -m 0755 "$TMP" "$DEST"
    fi
}

# Self first so we detect if it changed
fetch_file common/script_update.sh          "$BIRDDOG_ROOT/common/script_update.sh"

fetch_file common/golden_image_creation.sh  "$BIRDDOG_ROOT/common/golden_image_creation.sh"
fetch_file common/device_configure.sh       "$BIRDDOG_ROOT/common/device_configure.sh"
fetch_file common/oobe_reset.sh             "$BIRDDOG_ROOT/common/oobe_reset.sh"
fetch_file bdm/bdm_AP_setup.sh              "$BIRDDOG_ROOT/bdm/bdm_AP_setup.sh"
fetch_file bdm/bdm_mediamtx_setup.sh        "$BIRDDOG_ROOT/bdm/bdm_mediamtx_setup.sh"
fetch_file bdm/bdm_web_setup.sh             "$BIRDDOG_ROOT/bdm/bdm_web_setup.sh"
fetch_file bdc/bdc_fresh_install_setup.sh   "$BIRDDOG_ROOT/bdc/bdc_fresh_install_setup.sh"
fetch_file mesh/add_mesh_network.sh         "$BIRDDOG_ROOT/mesh/add_mesh_network.sh"

# --------------------------------------------------
# ABORT IF ANY FETCH FAILED
# --------------------------------------------------

if [[ "$FETCH_FAILED" -eq 1 ]]; then
    echo ""
    echo "ERROR: One or more scripts failed to fetch"
    echo "       Platform identity not updated"
    echo "       Staged updater (if any) not activated"
    rm -f "$BIRDDOG_ROOT/common/script_update.sh.new"
    exit 1
fi

# --------------------------------------------------
# PERMISSIONS
# --------------------------------------------------

echo ""
echo "[Update] Setting permissions"

chmod +x "$BIRDDOG_ROOT"/common/*.sh
chmod +x "$BIRDDOG_ROOT"/bdm/*.sh
chmod +x "$BIRDDOG_ROOT"/bdc/*.sh
chmod +x "$BIRDDOG_ROOT"/mesh/*.sh

# --------------------------------------------------
# ACTIVATE STAGED SELF-UPDATER
# --------------------------------------------------

if [[ "$SELF_UPDATED" -eq 1 ]]; then
    echo "[Update] Activating new updater"
    mv -f "$BIRDDOG_ROOT/common/script_update.sh.new" \
          "$BIRDDOG_ROOT/common/script_update.sh"
    chmod +x "$BIRDDOG_ROOT/common/script_update.sh"
fi

# --------------------------------------------------
# WRITE VERSION IDENTITY
# --------------------------------------------------

echo "$REMOTE_COMMIT"              > "$COMMIT_FILE"
echo "commit-$REMOTE_COMMIT"       > "$VERSION_FILE"
date -u +"%Y-%m-%dT%H:%M:%SZ"     > "$BUILD_FILE"

# --------------------------------------------------

echo ""
echo "====================================="
echo "BirdDog update complete"
echo "  Commit : $REMOTE_COMMIT"
echo "====================================="
echo ""
echo "Reboot recommended to apply any service script changes."
echo ""
