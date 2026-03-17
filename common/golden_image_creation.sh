#!/bin/bash
set -e
set -o pipefail

LOG="/opt/birddog/logs/golden_image_creation.log"

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

mkdir -p /opt/birddog/logs
exec > >(tee -a "$LOG") 2>&1

echo "====================================="
echo "BirdDog Golden Image Creation"
echo "====================================="
echo ""

# --------------------------------------------------
# PRE-CHECK — is a full install actually needed?
# --------------------------------------------------

PRECHECK_PASS=1
PRECHECK_NOTES=()

BIRDDOG_ROOT="/opt/birddog"

for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git raspi-gpio ethtool curl tar iw wireless-tools; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        PRECHECK_PASS=0
        PRECHECK_NOTES+=("package missing: $pkg")
    fi
done

if [[ ! -f "$BIRDDOG_ROOT/mediamtx/mediamtx" ]]; then
    PRECHECK_PASS=0
    PRECHECK_NOTES+=("mediamtx binary missing")
fi

if [[ ! -f /etc/udev/rules.d/72-birddog-radios.rules ]]; then
    PRECHECK_PASS=0
    PRECHECK_NOTES+=("udev radio rules missing")
fi

if ! systemctl is-enabled birddog-block-onboard-wifi.service >/dev/null 2>&1; then
    PRECHECK_PASS=0
    PRECHECK_NOTES+=("onboard WiFi block service not enabled")
fi

if [[ ! -f /usr/local/bin/mesh ]]; then
    PRECHECK_PASS=0
    PRECHECK_NOTES+=("mesh CLI missing")
fi

# --------------------------------------------------
# INSTALL MODE
# --------------------------------------------------

if [[ -z "$BIRDDOG_MODE" ]]; then
    echo "Select install mode:"
    echo ""

    if [[ "$PRECHECK_PASS" -eq 1 ]]; then
        echo "  [F] Full install  (system verified — full install not required)"
    else
        echo "  [F] Full install"
        echo ""
        echo "  System check — full install recommended:"
        for NOTE in "${PRECHECK_NOTES[@]}"; do
            echo "    • $NOTE"
        done
        echo ""
    fi

    echo "  [R] Refresh (scripts only)"
    echo "  [X] Exit"
    echo ""
    read -r -p "Choice: " MODE

    case "$MODE" in
        F|f) BIRDDOG_MODE="full" ;;
        R|r) BIRDDOG_MODE="refresh" ;;
        X|x) echo "Exiting."; exit 0 ;;
        *) echo "Invalid selection"; exit 1 ;;
    esac
fi

echo "Mode: $BIRDDOG_MODE"
echo ""

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
    apt-get update

    # --------------------------------------------------
    echo "[Phase 1] Package Assurance"
    # --------------------------------------------------

    install_pkg() {
        local PKG="$1"
        if dpkg -s "$PKG" >/dev/null 2>&1; then
            printf "  %-8s %s\n" "OK" "$PKG"
        else
            printf "  %-8s %s\n" "INSTALL" "$PKG"
            apt-get install -y "$PKG"
        fi
    }

    for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool curl tar iw wireless-tools; do
        install_pkg "$pkg"
    done

    # --------------------------------------------------
    echo "[Phase 1.5] Installing MediaMTX"
    # --------------------------------------------------

    MEDIAMTX_DIR="$BIRDDOG_ROOT/mediamtx"
    MEDIAMTX_STAGE="/tmp/mediamtx_stage"
    MEDIAMTX_TAR="/tmp/mediamtx.tar.gz"
    MEDIAMTX_VERSION="v1.16.3"

    mkdir -p "$MEDIAMTX_DIR"

    if [[ ! -f "$MEDIAMTX_DIR/mediamtx" ]]; then
        echo "  Downloading MediaMTX $MEDIAMTX_VERSION (linux_arm64)..."
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
        rm -rf "$MEDIAMTX_STAGE" "$MEDIAMTX_TAR"
        echo "  MediaMTX installed at $MEDIAMTX_DIR/mediamtx"
    else
        echo "  MediaMTX already present — skipping"
    fi

    # --------------------------------------------------
    echo "[Phase 1.8] Radio interface naming (udev)"
    # --------------------------------------------------

    cat > /etc/udev/rules.d/72-birddog-radios.rules <<'UDEV'
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="brcmfmac",  NAME="wlan0"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mt76x2u",   NAME="wlan1"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="rtl8192cu", NAME="wlan2"
UDEV

    echo "  udev rules written → /etc/udev/rules.d/72-birddog-radios.rules"

    cat > /etc/systemd/system/birddog-block-onboard-wifi.service <<'SVC'
[Unit]
Description=BirdDog Block Onboard WiFi
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill block 0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC

    systemctl daemon-reload
    systemctl enable birddog-block-onboard-wifi.service
    echo "  onboard WiFi block service installed and enabled"

    # --------------------------------------------------
    echo "[Phase 1.9] Installing Mesh CLI"
    # --------------------------------------------------

    cat > /usr/local/bin/mesh <<'MESHCLI'
#!/bin/bash
# BirdDog Mesh CLI

IFACE="wlan1"
LOG="/opt/birddog/mesh/mesh_runtime.log"

# --------------------------------------------------
# HELPERS
# --------------------------------------------------

resolve_peer() {
    local MAC="$1"
    local IP
    IP=$(ip neigh show dev "$IFACE" 2>/dev/null | grep "$MAC" | awk '{print $1}' | head -n1)
    if [[ -n "$IP" ]]; then
        local HOST
        HOST=$(avahi-resolve-address "$IP" 2>/dev/null | awk '{print $2}' | sed 's/\.local//')
        [[ -n "$HOST" ]] && echo "$HOST" && return
        echo "$IP"
        return
    fi
    echo "$MAC"
}

mesh_joined() {
    local TYPE
    TYPE=$(iw dev "$IFACE" info 2>/dev/null | awk '/type/ {print $2}')
    [[ "$TYPE" == "mesh" ]]
}

mesh_ip() {
    ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet )[^/]+'
}

peer_macs() {
    iw dev "$IFACE" station dump 2>/dev/null | awk '/^Station/ {print $2}'
}

service_state() {
    systemctl is-active birddog-mesh 2>/dev/null
}

stream_state() {
    systemctl is-active birddog-stream 2>/dev/null
}

# --------------------------------------------------
# STATUS
# --------------------------------------------------

cmd_status() {
    echo "================================="
    echo "BirdDog Mesh Status"
    echo "  Node : $(hostname)"
    echo "  Time : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================="
    echo ""

    echo "  Mesh service   : $(service_state)"

    if ! mesh_joined; then
        echo "  Interface      : NOT in mesh mode"
        echo ""
        echo "  Run: birddog verify  for full diagnostics"
        echo ""
        return
    fi

    local IP PEERS
    IP=$(mesh_ip)
    PEERS=$(peer_macs | wc -l)

    echo "  Interface      : mesh (wlan1)"
    echo "  Mesh IP        : ${IP:-unassigned}"
    echo "  Direct peers   : $PEERS"

    if [[ -f /opt/birddog/bdc/bdc.conf ]]; then
        echo "  Stream service : $(stream_state)"
        local STREAM
        STREAM=$(grep -oP '(?<=STREAM_NAME=).+' /opt/birddog/bdc/bdc.conf 2>/dev/null || true)
        [[ -n "$STREAM" ]] && echo "  Stream name    : $STREAM"
    fi

    echo ""

    if [[ "$PEERS" -gt 0 ]]; then
        printf "  %-14s %-16s %-10s %-10s\n" "Peer" "IP" "Signal" "TX Rate"
        printf "  %s\n" "---------------------------------------------------"
        while IFS= read -r MAC; do
            local HOST PEER_IP SIG RATE
            HOST=$(resolve_peer "$MAC")
            PEER_IP=$(ip neigh show dev "$IFACE" 2>/dev/null | grep "$MAC" | awk '{print $1}' | head -n1)
            SIG=$(iw dev "$IFACE" station dump 2>/dev/null | grep -A30 "$MAC" | awk '/signal:/ {print $2; exit}')
            RATE=$(iw dev "$IFACE" station dump 2>/dev/null | grep -A30 "$MAC" | awk '/tx bitrate:/ {print $3; exit}')
            printf "  %-14s %-16s %-10s %-10s\n" \
                "${HOST:-$MAC}" "${PEER_IP:--}" "${SIG:--} dBm" "${RATE:--} Mbps"
        done < <(peer_macs)
        echo ""
    fi
}

# --------------------------------------------------
# PEERS
# --------------------------------------------------

cmd_peers() {
    echo "================================="
    echo "BirdDog Mesh Peers"
    echo "================================="

    if ! mesh_joined; then
        echo "  Not in mesh mode"
        return
    fi

    local COUNT=0
    while IFS= read -r MAC; do
        COUNT=$((COUNT+1))
        local HOST PEER_IP SIG RATE TX_BYTES RX_BYTES INACTIVE
        HOST=$(resolve_peer "$MAC")
        PEER_IP=$(ip neigh show dev "$IFACE" 2>/dev/null | grep "$MAC" | awk '{print $1}' | head -n1)
        SIG=$(iw dev "$IFACE" station dump 2>/dev/null | grep -A30 "$MAC" | awk '/signal:/ {print $2; exit}')
        RATE=$(iw dev "$IFACE" station dump 2>/dev/null | grep -A30 "$MAC" | awk '/tx bitrate:/ {print $3; exit}')
        TX_BYTES=$(iw dev "$IFACE" station dump 2>/dev/null | grep -A30 "$MAC" | awk '/tx bytes:/ {print $3; exit}')
        RX_BYTES=$(iw dev "$IFACE" station dump 2>/dev/null | grep -A30 "$MAC" | awk '/rx bytes:/ {print $3; exit}')
        INACTIVE=$(iw dev "$IFACE" station dump 2>/dev/null | grep -A30 "$MAC" | awk '/inactive time:/ {print $3; exit}')

        echo ""
        echo "  Peer     : ${HOST:-unknown}"
        echo "  MAC      : $MAC"
        echo "  IP       : ${PEER_IP:--}"
        echo "  Signal   : ${SIG:--} dBm"
        echo "  TX Rate  : ${RATE:--} Mbps"
        echo "  TX Bytes : ${TX_BYTES:--}"
        echo "  RX Bytes : ${RX_BYTES:--}"
        echo "  Inactive : ${INACTIVE:--} ms"
    done < <(peer_macs)

    [[ "$COUNT" -eq 0 ]] && echo "" && echo "  No peers currently visible"
    echo ""
}

# --------------------------------------------------
# MAP
# --------------------------------------------------

cmd_map() {
    echo "================================="
    echo "BirdDog Mesh Topology"
    echo "================================="

    if ! mesh_joined; then
        echo "  Not in mesh mode"
        return
    fi

    local SELF IP
    SELF=$(hostname)
    IP=$(mesh_ip)

    echo ""
    echo "  Self: $SELF ($IP)"
    echo ""
    echo "  Direct links:"

    local COUNT=0
    while IFS= read -r MAC; do
        COUNT=$((COUNT+1))
        local HOST SIG
        HOST=$(resolve_peer "$MAC")
        SIG=$(iw dev "$IFACE" station dump 2>/dev/null | grep -A30 "$MAC" | awk '/signal:/ {print $2; exit}')
        echo "    $SELF  <--[${SIG:--} dBm]-->  $HOST"
    done < <(peer_macs)

    [[ "$COUNT" -eq 0 ]] && echo "    (no direct peers)"

    echo ""
    echo "  Mesh routes:"
    local ROUTES=0
    while IFS= read -r line; do
        ROUTES=$((ROUTES+1))
        local DEST NEXTHOP DEST_HOST NEXT_HOST
        DEST=$(echo "$line" | awk '{print $1}')
        NEXTHOP=$(echo "$line" | grep -oP '(?<=via )[0-9.]+' || true)
        DEST_HOST=$(avahi-resolve-address "$DEST" 2>/dev/null | awk '{print $2}' | sed 's/\.local//')
        NEXT_HOST=$(avahi-resolve-address "$NEXTHOP" 2>/dev/null | awk '{print $2}' | sed 's/\.local//')
        echo "    ${DEST_HOST:-$DEST}  →  ${NEXT_HOST:-$NEXTHOP}"
    done < <(ip route show dev "$IFACE" 2>/dev/null | grep via)

    [[ "$ROUTES" -eq 0 ]] && echo "    (no multi-hop routes)"
    echo ""
}

# --------------------------------------------------
# GRAPH
# --------------------------------------------------

cmd_graph() {
    echo "================================="
    echo "BirdDog Mesh Graph"
    echo "================================="

    if ! mesh_joined; then
        echo "  Not in mesh mode"
        return
    fi

    local SELF IP PEERS
    SELF=$(hostname)
    IP=$(mesh_ip)
    PEERS=$(peer_macs | wc -l)

    echo ""
    echo "  $SELF ($IP)"

    local i=0
    while IFS= read -r MAC; do
        i=$((i+1))
        local HOST SIG
        HOST=$(resolve_peer "$MAC")
        SIG=$(iw dev "$IFACE" station dump 2>/dev/null | grep -A30 "$MAC" | awk '/signal:/ {print $2; exit}')
        if [[ "$i" -eq "$PEERS" ]]; then
            echo "  └── $HOST  (${SIG:--} dBm)"
        else
            echo "  ├── $HOST  (${SIG:--} dBm)"
        fi
    done < <(peer_macs)

    [[ "$PEERS" -eq 0 ]] && echo "  └── (no peers)"
    echo ""
}

# --------------------------------------------------
# LOG
# --------------------------------------------------

cmd_log() {
    local LINES="${1:-30}"
    if [[ -f "$LOG" ]]; then
        echo "=== Mesh Runtime Log (last $LINES lines) ==="
        echo ""
        tail -n "$LINES" "$LOG"
        echo ""
    else
        echo "  Log not found: $LOG"
    fi
}

# --------------------------------------------------
# WATCH
# --------------------------------------------------

cmd_watch() {
    local INTERVAL="${1:-5}"
    echo "  Watching mesh — refresh every ${INTERVAL}s  (Ctrl+C to stop)"
    echo ""
    while true; do
        clear
        cmd_status
        sleep "$INTERVAL"
    done
}

# --------------------------------------------------
# PING
# --------------------------------------------------

cmd_ping() {
    echo "================================="
    echo "BirdDog Mesh Ping"
    echo "================================="
    echo ""

    if ! mesh_joined; then
        echo "  Not in mesh mode"
        return
    fi

    local COUNT=0
    local BASE
    BASE=$(mesh_ip | grep -oP '^\d+\.\d+\.\d+')

    for i in 10 20 30 40 50; do
        local TARGET="${BASE}.${i}"
        local SELF_IP
        SELF_IP=$(mesh_ip)
        [[ "$TARGET" == "$SELF_IP" ]] && continue
        if ping -c1 -W1 -I "$IFACE" "$TARGET" >/dev/null 2>&1; then
            local HOST
            HOST=$(avahi-resolve-address "$TARGET" 2>/dev/null | awk '{print $2}' | sed 's/\.local//')
            echo "  $TARGET  ${HOST:+($HOST)}  REACHABLE"
            COUNT=$((COUNT+1))
        fi
    done

    [[ "$COUNT" -eq 0 ]] && echo "  No mesh nodes reachable"
    echo ""
}

# --------------------------------------------------
# SCAN
# --------------------------------------------------

cmd_scan() {
    echo "Scanning for mesh networks on wlan1..."
    echo ""
    iw dev "$IFACE" scan 2>/dev/null | grep -E 'SSID|signal' || echo "  (no results — adapter may need to leave mesh mode first)"
    echo ""
}

# --------------------------------------------------
# DISPATCH
# --------------------------------------------------

case "$1" in
    status)     cmd_status ;;
    peers)      cmd_peers ;;
    map)        cmd_map ;;
    graph)      cmd_graph ;;
    log)        cmd_log "${2:-30}" ;;
    watch)      cmd_watch "${2:-5}" ;;
    ping)       cmd_ping ;;
    scan)       cmd_scan ;;
    ""  | help)
        echo ""
        echo "================================="
        echo "BirdDog Mesh CLI"
        echo "================================="
        echo ""
        echo "  mesh status        mesh health + peer table"
        echo "  mesh peers         detailed RF metrics per peer"
        echo "  mesh map           direct links + multi-hop routes"
        echo "  mesh graph         topology tree"
        echo "  mesh log [N]       last N lines of runtime log (default 30)"
        echo "  mesh watch [N]     live status refresh every N seconds (default 5)"
        echo "  mesh ping          ping all expected mesh nodes"
        echo "  mesh scan          scan for mesh SSIDs"
        echo "  mesh help          this menu"
        echo ""
        echo "================================="
        echo ""
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'mesh help' for usage"
        exit 1
        ;;
esac
MESHCLI

    chmod +x /usr/local/bin/mesh
    echo "  Mesh CLI installed → /usr/local/bin/mesh"

fi  # end full install

# --------------------------------------------------
# COMMIT
# --------------------------------------------------

echo "[Phase 2] Commit State Check"

REMOTE_COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)

if [[ -z "$REMOTE_COMMIT" ]]; then
    echo "  ERROR resolving remote commit"
    exit 1
fi

LOCAL_COMMIT="none"
[[ -f "$COMMIT_FILE" ]] && LOCAL_COMMIT=$(cat "$COMMIT_FILE")

printf "  Remote : %s\n" "$REMOTE_COMMIT"
printf "  Local  : %s\n" "$LOCAL_COMMIT"

if [[ "$REMOTE_COMMIT" == "$LOCAL_COMMIT" ]]; then
    printf "  State  : Already at latest commit\n"
else
    printf "  State  : Advancing %s → %s\n" "$LOCAL_COMMIT" "$REMOTE_COMMIT"
fi

echo ""

# --------------------------------------------------
# FETCH
# --------------------------------------------------

echo "[Phase 3] Fetch Scripts"

FETCH_FAILED=0

fetch_file() {
    local REMOTE_PATH="$1"
    local LOCAL_PATH="$2"
    local TMP="/tmp/birddog_fetch.$$"

    if curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/${REMOTE_COMMIT}/${REMOTE_PATH}" -o "$TMP" 2>/dev/null; then
        if [[ ! -f "$LOCAL_PATH" ]]; then
            printf "  %-8s %s\n" "NEW" "$REMOTE_PATH"
            install -m 0755 "$TMP" "$LOCAL_PATH"
        elif cmp -s "$TMP" "$LOCAL_PATH"; then
            printf "  %-8s %s\n" "UNCHANGED" "$REMOTE_PATH"
            rm -f "$TMP"
        else
            printf "  %-8s %s\n" "UPDATED" "$REMOTE_PATH"
            install -m 0755 "$TMP" "$LOCAL_PATH"
        fi
    else
        printf "  %-8s %s\n" "FAILED" "$REMOTE_PATH"
        rm -f "$TMP"
        FETCH_FAILED=1
    fi
}

fetch_file common/golden_image_creation.sh  "$BIRDDOG_ROOT/common/golden_image_creation.sh"
fetch_file common/script_update.sh          "$BIRDDOG_ROOT/common/script_update.sh"
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
    echo "ERROR: One or more scripts failed to fetch — aborting"
    echo "       Platform identity not updated"
    exit 1
fi

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
# CLI
# --------------------------------------------------

echo "[Phase 5] Installing BirdDog CLI"

BIRDDOG_CLI="/usr/local/bin/birddog"

cat > "$BIRDDOG_CLI" <<BIRDDOG_EOF
#!/bin/bash
BIRDDOG_ROOT="/opt/birddog"

case "\$1" in
    install)    exec sudo bash "\$BIRDDOG_ROOT/common/golden_image_creation.sh" ;;
    update)     exec sudo bash "\$BIRDDOG_ROOT/common/script_update.sh" ;;
    configure)  exec sudo bash "\$BIRDDOG_ROOT/common/device_configure.sh" ;;
    reset)      exec sudo bash "\$BIRDDOG_ROOT/common/oobe_reset.sh" ;;
    verify)     exec sudo bash "\$BIRDDOG_ROOT/common/verify_node.sh" ;;
    radios)
        echo "Radio layout:"
        for IFACE in wlan0 wlan1 wlan2; do
            if ip link show "\$IFACE" >/dev/null 2>&1; then
                DRV=\$(readlink /sys/class/net/\$IFACE/device/driver 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
                MODE=\$(iw dev "\$IFACE" info 2>/dev/null | awk '/type/ {print \$2}' || echo "unknown")
                STATE=\$(ip link show "\$IFACE" | grep -oP '(?<=state )\w+' || echo "unknown")
                printf "  %-6s driver=%-12s mode=%-10s state=%s\n" "\$IFACE" "\$DRV" "\$MODE" "\$STATE"
            fi
        done
        ;;
    version)
        COMMIT=\$(cat "\$BIRDDOG_ROOT/version/COMMIT" 2>/dev/null || echo "unknown")
        BUILD=\$(cat "\$BIRDDOG_ROOT/version/BUILD" 2>/dev/null || echo "unknown")
        echo "BirdDog"
        echo "  Commit : \$COMMIT"
        echo "  Built  : \$BUILD"
        echo "  Host   : \$(hostname)"
        ;;
    ""|help)
        echo ""
        echo "BirdDog CLI"
        echo ""
        echo "  birddog install     full golden image install"
        echo "  birddog update      fetch latest scripts"
        echo "  birddog configure   assign role and configure node"
        echo "  birddog reset       factory reset to unconfigured state"
        echo "  birddog verify      run node health check"
        echo "  birddog radios      show radio interface layout"
        echo "  birddog version     show platform version"
        echo ""
        echo "  mesh help           mesh CLI reference"
        echo ""
        ;;
    *)
        echo "Unknown command: \$1"
        echo "Run 'birddog help' for usage"
        exit 1
        ;;
esac
BIRDDOG_EOF

chmod +x "$BIRDDOG_CLI"
echo "  BirdDog CLI installed → $BIRDDOG_CLI"

# --------------------------------------------------
# DONE
# --------------------------------------------------

echo "[Phase 6] Finalization"
echo "====================================="
echo "Golden image creation complete"
printf "  Commit : %s\n" "$REMOTE_COMMIT"
printf "  Mode   : %s\n" "$BIRDDOG_MODE"
echo "====================================="
echo ""

if [[ "$BIRDDOG_MODE" == "full" ]]; then
    echo "====================================="
    echo "⚠  REBOOT REQUIRED"
    echo "====================================="
    echo ""
    echo "  Udev rules and system services were installed."
    echo "  Reboot before running birddog configure."
    echo ""
    echo "    sudo reboot"
    echo ""
else
    echo "Next step: birddog configure"
fi
