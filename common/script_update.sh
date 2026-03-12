#!/bin/bash
set -e
set -o pipefail

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
# Commit Resolve
# --------------------------------------------------

echo "[Update] Resolving Repository State"

REMOTE_COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)

if [[ -z "$REMOTE_COMMIT" ]]; then
    echo "ERROR resolving commit"
    exit 1
fi

if ! [[ "$REMOTE_COMMIT" =~ ^[0-9a-f]{7}$ ]]; then
    echo "ERROR invalid commit format: $REMOTE_COMMIT"
    exit 1
fi

LOCAL_COMMIT="none"
[[ -f "$COMMIT_FILE" ]] && LOCAL_COMMIT=$(cat "$COMMIT_FILE")

echo "Remote: $REMOTE_COMMIT"
echo "Local : $LOCAL_COMMIT"

if [[ "$REMOTE_COMMIT" == "$LOCAL_COMMIT" ]]; then
    echo "State : Already at latest platform commit"
    COMMIT_ADVANCE=0
else
    echo "State : Advancing platform commit"
    echo "        $LOCAL_COMMIT → $REMOTE_COMMIT"
    COMMIT_ADVANCE=1
fi

echo ""

# --------------------------------------------------
# Fetch Scripts
# --------------------------------------------------

echo "[Update] Fetching Scripts"

UPDATE_FAILED=0

fetch_file() {

    TMP="/tmp/birddog_fetch.$$"

    if ! curl --connect-timeout 10 --retry 3 --retry-delay 2 -fsSL \
        "https://raw.githubusercontent.com/badandyc/BirdDog/$REMOTE_COMMIT/$1" \
        -o "$TMP"; then
        echo "FAILED $1"
        UPDATE_FAILED=1
        return
    fi

    # Self-updater staging protection
    if [[ "$1" == "common/script_update.sh" ]]; then
        echo "STAGED UPDATE $1"
        sudo install -m 0755 "$TMP" "$2.new"
        return
    fi

    if [[ ! -f "$2" ]]; then
        echo "NEW $1"
        sudo install -m 0755 "$TMP" "$2"
        return
    fi

    if cmp -s "$TMP" "$2"; then
        echo "UNCHANGED $1"
        rm -f "$TMP"
    else
        echo "UPDATED $1"
        sudo install -m 0755 "$TMP" "$2"
    fi
}

fetch_file common/script_update.sh "$BIRDDOG_ROOT/common/script_update.sh"
fetch_file bdm/bdm_initial_setup.sh "$BIRDDOG_ROOT/bdm/bdm_initial_setup.sh"
fetch_file bdm/bdm_AP_setup.sh "$BIRDDOG_ROOT/bdm/bdm_AP_setup.sh"
fetch_file bdm/bdm_mediamtx_setup.sh "$BIRDDOG_ROOT/bdm/bdm_mediamtx_setup.sh"
fetch_file bdm/bdm_web_setup.sh "$BIRDDOG_ROOT/bdm/bdm_web_setup.sh"
fetch_file bdc/bdc_fresh_install_setup.sh "$BIRDDOG_ROOT/bdc/bdc_fresh_install_setup.sh"
fetch_file mesh/add_mesh_network.sh "$BIRDDOG_ROOT/mesh/add_mesh_network.sh"
fetch_file common/device_configure.sh "$BIRDDOG_ROOT/common/device_configure.sh"
fetch_file common/radio_map_setup.sh "$BIRDDOG_ROOT/common/radio_map_setup.sh"
fetch_file common/oobe_reset.sh "$BIRDDOG_ROOT/common/oobe_reset.sh"
fetch_file common/golden_image_creation.sh "$BIRDDOG_ROOT/common/golden_image_creation.sh"

# --------------------------------------------------
# Abort Identity Write if Failure
# --------------------------------------------------

if [[ "$UPDATE_FAILED" -eq 1 ]]; then
    echo ""
    echo "ERROR: One or more script fetches failed."
    echo "Platform identity not advanced."
    exit 1
fi

# --------------------------------------------------
# Identity Write
# --------------------------------------------------

echo "$REMOTE_COMMIT" > "$COMMIT_FILE"
echo "commit-$REMOTE_COMMIT" > "$VERSION_FILE"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$BUILD_FILE"

# --------------------------------------------------
# Permissions Sweep (Safety)
# --------------------------------------------------

echo "[Update] Setting Permissions"

chmod +x "$BIRDDOG_ROOT"/common/*.sh
chmod +x "$BIRDDOG_ROOT"/bdm/*.sh
chmod +x "$BIRDDOG_ROOT"/bdc/*.sh
chmod +x "$BIRDDOG_ROOT"/mesh/*.sh

# --------------------------------------------------
# Activate New Updater (Atomic)
# --------------------------------------------------

if [[ -f "$BIRDDOG_ROOT/common/script_update.sh.new" ]]; then
    echo "[Update] Activating new updater"
    sudo mv -f \
        "$BIRDDOG_ROOT/common/script_update.sh.new" \
        "$BIRDDOG_ROOT/common/script_update.sh"
    sudo chmod +x "$BIRDDOG_ROOT/common/script_update.sh"
fi

echo ""
echo "BirdDog script update complete."
echo ""
