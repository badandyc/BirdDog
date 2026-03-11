#!/bin/bash
set -e

echo "=== BirdDog Golden Image Creation ==="

BIRDDOG_ROOT=/opt/birddog
VERSION_DIR=$BIRDDOG_ROOT/version
COMMIT_FILE=$VERSION_DIR/COMMIT

mkdir -p $BIRDDOG_ROOT/{bdm,bdc,mesh,common,mediamtx,web,logs,version}

echo "[Phase 1] Package Assurance"

#sudo apt update

for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool; do
    dpkg -s "$pkg" >/dev/null 2>&1 || sudo apt install -y "$pkg"
done

echo "Packages ready."


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

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/$REMOTE_PATH" -o "$TMP_FILE"

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
find "$BIRDDOG_ROOT" -name "*.sh" -exec sha256sum {} \; | sort > "$VERSION_DIR/MANIFEST"
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

MESH_IF="wlan1"
MESH_LOG="/opt/birddog/mesh/mesh_runtime.log"

mesh_status() {

SNAP_STATION="$(iw dev $MESH_IF station dump 2>/dev/null)"
SNAP_NEIGH="$(ip neigh show dev $MESH_IF 2>/dev/null)"
STATE="$(grep 'STATE →' $MESH_LOG | tail -1 | awk '{print $4}')"

echo ""
echo "================================="
echo "BirdDog Mesh Status"
echo "================================="

if ! ip link show $MESH_IF >/dev/null 2>&1; then
    echo "Interface     : MISSING"
    return
fi

PEERS=$(echo "$SNAP_STATION" | grep -c '^Station')

IP=$(ip -4 addr show $MESH_IF 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)

echo "Node          : $(hostname)"
echo "Runtime State : ${STATE:-UNKNOWN}"
echo "Mesh IP       : ${IP:-NONE}"
echo "Peers         : $PEERS"
echo ""
}

mesh_peers() {

STATION="$(iw dev $MESH_IF station dump 2>/dev/null)"
NEIGH="$(ip neigh show dev $MESH_IF 2>/dev/null)"

echo ""
echo "================================="
echo "BirdDog Mesh Peers"
echo "================================="

printf "%-10s %-15s %-8s %-8s %-8s\n" "Node" "IP" "Signal" "Rate" "Metric"

echo "$STATION" | awk '
/^Station/ {mac=$2}
/signal:/ {sig=$2}
/tx bitrate:/ {rate=$3}
/metric:/ {metric=$2; print mac,sig,rate,metric}
' | while read MAC SIG RATE METRIC
do
    IP=$(echo "$NEIGH" | awk -v m="$MAC" '$5==m {print $1}')
    NAME=$(getent hosts "$IP" | awk '{print $2}')
    printf "%-10s %-15s %-8s %-8s %-8s\n" "${NAME:-$MAC}" "${IP:-?}" "$SIG" "$RATE" "$METRIC"
done | sort -k5 -n

echo ""
}

mesh_state() {
echo ""
echo "================================="
echo "BirdDog Mesh Runtime State"
echo "================================="
grep 'STATE →' "$MESH_LOG" | tail -10
echo ""
}

mesh_map() {

STATION="$(iw dev $MESH_IF station dump 2>/dev/null)"
NEIGH="$(ip neigh show dev $MESH_IF 2>/dev/null)"

echo ""
echo "================================="
echo "BirdDog Mesh Map"
echo "================================="

echo "$(hostname)"

echo "$STATION" | awk '
/^Station/ {mac=$2}
/metric:/ {metric=$2; print mac,metric}
' | while read MAC METRIC
do
    IP=$(echo "$NEIGH" | awk -v m="$MAC" '$5==m {print $1}')
    NAME=$(getent hosts "$IP" | awk '{print $2}')
    echo " ├─ ${NAME:-$MAC} (metric $METRIC)"
done | sort -k4 -n

echo ""
}

mesh_graph() {

echo ""
echo "================================="
echo "BirdDog Mesh Graph"
echo "================================="

iw dev $MESH_IF mpath dump 2>/dev/null | awk '
/dest/ {dest=$2}
/next hop/ {hop=$3}
/metric/ {metric=$2; print dest,hop,metric}
'

echo ""
}

mesh_scan() {

echo ""
echo "================================="
echo "BirdDog RF Scan"
echo "================================="

iw dev $MESH_IF scan 2>/dev/null | grep -E 'BSS|signal|SSID'

echo ""
}

mesh_debug() {

echo "===== IP ====="
ip addr show $MESH_IF

echo ""
echo "===== STATION ====="
iw dev $MESH_IF station dump

echo ""
echo "===== NEIGH ====="
ip neigh show dev $MESH_IF

echo ""
echo "===== ROUTES ====="
iw dev $MESH_IF mpath dump 2>/dev/null

echo ""
echo "===== LOG ====="
tail -20 $MESH_LOG
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

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/golden_image_creation.sh?$(date +%s)" \
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

if systemctl is-active birddog-mesh.service >/dev/null 2>&1 && \
   ip link show $MESH_IF >/dev/null 2>&1 && \
   iw dev $MESH_IF info 2>/dev/null | grep -q "mesh id birddog-mesh"; then
    echo "Mesh service     : OK"
else
    echo "Mesh service     : DOWN"
fi

systemctl is-active nginx >/dev/null 2>&1 && echo "Web service      : OK" || true

echo ""
}

echo ""
echo "================================="
echo "BirdDog CLI"
echo "================================="

case "$1" in

mesh)
case "$2" in
status) mesh_status ;;
peers) mesh_peers ;;
state) mesh_state ;;
map) mesh_map ;;
graph) mesh_graph ;;
scan) mesh_scan ;;
debug) mesh_debug ;;
*) echo "mesh commands: status | peers | state | map | graph | scan | debug" ;;
esac
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
echo " birddog mesh status|peers|state|map|graph|scan|debug"
echo " birddog install"
echo " birddog configure"
echo " birddog update"
echo " birddog verify"
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
