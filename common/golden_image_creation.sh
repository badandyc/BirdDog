#!/bin/bash
set -e
set -o pipefail

BIRDDOG_VERSION="2.0"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG="/opt/birddog/logs/golden_image_creation_${TIMESTAMP}.log"

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

for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool curl tar iw wireless-tools python3-rpi.gpio python3-pip batctl ifupdown; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        PRECHECK_PASS=0
        PRECHECK_NOTES+=("package missing: $pkg")
    fi
done

# network-manager must be absent
if dpkg -s "network-manager" >/dev/null 2>&1; then
    PRECHECK_PASS=0
    PRECHECK_NOTES+=("network-manager present — must be purged")
fi

# unattended-upgrades must be absent — causes dpkg lock conflicts in the field
if dpkg -s "unattended-upgrades" >/dev/null 2>&1; then
    PRECHECK_PASS=0
    PRECHECK_NOTES+=("unattended-upgrades present — must be purged")
fi

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

if [[ ! -f /usr/local/bin/birddog_day.py ]]; then
    PRECHECK_PASS=0
    PRECHECK_NOTES+=("birddog_day daemon missing")
fi

# --------------------------------------------------
# INSTALL MODE
# --------------------------------------------------

if [[ -z "$BIRDDOG_MODE" ]]; then
    echo "Select install mode:"
    echo ""

    if [[ "$PRECHECK_PASS" -eq 1 ]]; then
        echo "  [R] Re-install  (system verified — re-install not required)"
    else
        echo "  [R] Re-install"
        echo ""
        echo "  System check — re-install recommended:"
        for NOTE in "${PRECHECK_NOTES[@]}"; do
            echo "    • $NOTE"
        done
        echo ""
    fi

    echo "  [X] Exit"
    echo ""
    echo "  To refresh scripts only: birddog update"
    echo ""

    while true; do
        read -r -p "Choice: " MODE
        case "$MODE" in
            R) BIRDDOG_MODE="full"    ; break ;;
            X) echo "Exiting."; exit 0 ;;
            *) echo "  Invalid — enter R or X" ;;
        esac
    done
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

    # Tear down any active MAVLink bridge session before install.
    MAVLINK_CONF_PATH="/opt/birddog/bdm/mavlink.conf"
    if pgrep -f "mavproxy" >/dev/null 2>&1; then
        echo "  Stopping active MAVLink bridge..."
        pkill -f "mavproxy" 2>/dev/null || true
        sleep 1
    fi
    WLAN0_RFKILL_IDX=$(cat /sys/class/net/wlan0/phy80211/rfkill*/index 2>/dev/null)
    if [[ -n "$WLAN0_RFKILL_IDX" ]]; then
        echo 1 | tee "/sys/class/rfkill/rfkill${WLAN0_RFKILL_IDX}/soft" >/dev/null 2>&1 || true
    fi
    ip link set wlan0 down 2>/dev/null || true
    rm -f "$MAVLINK_CONF_PATH" 2>/dev/null || true

    echo "[Phase 0] Updating package index"

    # Stop and disable apt background timers and unattended-upgrades.
    # apt-daily.timer and apt-daily-upgrade.timer run apt in the background
    # and hold the dpkg lock, causing install failures in the field.
    systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl disable unattended-upgrades 2>/dev/null || true
    pkill -f "unattended-upgrades" 2>/dev/null || true
    sleep 2
    # Release any stale dpkg locks left by background apt processes
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
    dpkg --configure -a 2>/dev/null || true

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

    for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool curl tar iw wireless-tools python3-rpi.gpio python3-pip batctl ifupdown; do
        install_pkg "$pkg"
    done

    # Purge network-manager, rfkill, and unattended-upgrades.
    # network-manager conflicts with direct interface control.
    # rfkill userspace tool replaced by sysfs writes.
    # unattended-upgrades runs apt in the background and causes lock
    # conflicts during field installs — must not be present on deployed nodes.
    echo ""
    echo "  Purging network-manager, rfkill, unattended-upgrades..."
    apt-get purge -y network-manager rfkill unattended-upgrades 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    echo "  Done"

    # Configure eth0 for DHCP via ifupdown before NetworkManager is gone
    # so SSH does not drop. ifupdown takes over eth0 immediately.
    echo ""
    echo "  Configuring eth0 DHCP via ifupdown..."
    cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
    echo "  /etc/network/interfaces written"

    # Configure dhcpcd to use MAC address as DHCP client identifier.
    # By default dhcpcd uses a DUID which can change, causing the router
    # to assign a different IP on each fresh boot. Setting clientid forces
    # dhcpcd to identify by MAC, giving a stable lease across reboots.
    sed -i 's/^#clientid/clientid/' /etc/dhcpcd.conf
    sed -i 's/^duid/#duid/' /etc/dhcpcd.conf
    echo "  dhcpcd configured for MAC-based lease identity"

    # --------------------------------------------------
    echo "[Phase 1.4] Installing MAVProxy"
    # --------------------------------------------------

    pip3 install MAVProxy future --break-system-packages --quiet 2>/dev/null || true
    echo "  MAVProxy installed"

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
    echo "[Phase 1.75] batctl capability — cap_net_admin"
    # --------------------------------------------------

    # batctl requires cap_net_admin to access batman-adv kernel interfaces.
    # setcap grants this capability directly to the binary so any user can
    # run batctl without sudo — cleaner than a sudoers rule.
    setcap cap_net_admin+eip /usr/sbin/batctl
    echo "  cap_net_admin granted → /usr/sbin/batctl"

    # --------------------------------------------------
    echo "[Phase 1.8] Radio interface naming (udev)"
    # --------------------------------------------------

    # wlan0        — brcmfmac onboard, blocked by birddog-block-onboard-wifi.service
    #                only unblocked temporarily for birddog mavlink (ELRS backpack)
    # wlan_mesh_5  — MT7612U (Comfast CF-WU782AC), 5 GHz batman-adv backbone
    # wlan_ap      — RTL8192CU (Edimax), BDM access point + Mission Planner network
    # wlan_mesh_24 — RT5370, reserved (no rule yet — hardware not yet on hand)
    cat > /etc/udev/rules.d/72-birddog-radios.rules <<'UDEV'
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="brcmfmac",  NAME="wlan0"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="mt76x2u",   NAME="wlan_mesh_5"
SUBSYSTEM=="net", ACTION=="add", DRIVERS=="rtl8192cu", NAME="wlan_ap"
UDEV

    udevadm control --reload-rules
    # Re-trigger add events for already-enumerated net interfaces so udev
    # renames them without requiring a reboot.
    udevadm trigger --subsystem-match=net --action=add
    sleep 2
    echo "  udev rules written → /etc/udev/rules.d/72-birddog-radios.rules"
    echo "  udev triggered — interfaces renamed without reboot"

    cat > /etc/systemd/system/birddog-block-onboard-wifi.service <<'SVC'
[Unit]
Description=BirdDog Block Onboard WiFi
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
# Block onboard wifi by subsystem — sdio is always the onboard brcmfmac.
# USB adapters show as usb subsystem and are never blocked here.
ExecStart=/bin/bash -c '    sleep 3;     for rf in /sys/class/rfkill/rfkill*/; do         subsystem=$(basename $(readlink $rf/device/device/subsystem 2>/dev/null) 2>/dev/null);         idx=$(cat $rf/index 2>/dev/null);         if [[ "$subsystem" == "sdio" && -n "$idx" ]]; then             echo 1 | tee "/sys/class/rfkill/rfkill${idx}/soft" >/dev/null 2>&1 || true;         fi;     done'
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

    # The mesh CLI uses batman-adv primitives (batctl) rather than 802.11s iw
    # commands. bat0 is the virtual L3 interface batman-adv presents; all
    # routing and peer queries go through it and batctl.
    cat > /usr/local/bin/mesh <<'MESHCLI'
#!/bin/bash
# BirdDog Mesh CLI

MESH_IF="wlan_mesh_5"
BAT_IF="bat0"
LOG="/opt/birddog/mesh/mesh_runtime.log"

# --------------------------------------------------
# HELPERS
# --------------------------------------------------

resolve_peer() {
    local ORIG_MAC="$1"
    # Map originator MAC (wlan_mesh_5) → bat0 client MAC via translation table
    # batctl tg fields: $1=* $2=clientMAC $3=VID $4=flags $5=( $6=ttvn) $7=originatorMAC
    # Filter multicast MACs (33:33:*, 01:00:*, ff:*) — only unicast clients
    local CLIENT_MAC
    CLIENT_MAC=$(batctl tg 2>/dev/null | awk -v orig="$ORIG_MAC"         '$7==orig && $2!~/^33:33/ && $2!~/^01:00/ && $2!~/^ff:/ {print $2; exit}')
    local IP
    IP=$(ip neigh show dev "$BAT_IF" 2>/dev/null | awk -v mac="$CLIENT_MAC"         '$3==mac {print $1; exit}')
    if [[ -n "$IP" ]]; then
        local HOST
        HOST=$(avahi-resolve-address "$IP" 2>/dev/null | awk '{print $2}' | sed 's/\.local//')
        [[ -n "$HOST" ]] && echo "$HOST" && return
        echo "$IP"
        return
    fi
    echo "$ORIG_MAC"
}

mesh_joined() {
    # batman-adv is active when bat0 exists and wlan_mesh_5 is listed
    # as a batman-adv interface via batctl
    ip link show "$BAT_IF" >/dev/null 2>&1 && \
        batctl if 2>/dev/null | grep -q "$MESH_IF"
}

mesh_ip() {
    ip -4 addr show "$BAT_IF" 2>/dev/null | grep -oP '(?<=inet )[^/]+'
}

peer_macs() {
    # Direct (1-hop) batman-adv neighbors
    batctl neighbors 2>/dev/null | awk 'NR>2 && /[0-9a-f:]/{print $2}' | sort -u
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
        echo "  Interface      : NOT in mesh (batman-adv not active)"
        echo ""
        echo "  Run: birddog verify  for full diagnostics"
        echo ""
        return
    fi

    local IP PEERS
    IP=$(mesh_ip)
    PEERS=$(peer_macs | wc -l)

    echo "  Interface      : wlan_mesh_5 → bat0 (batman-adv)"
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
        printf "  %-14s %-16s %-10s %-10s\n" "Peer" "IP" "TQ" "Last seen"
        printf "  %s\n" "---------------------------------------------------"
        while IFS= read -r MAC; do
            local HOST PEER_IP TQ LASTSEEN
            HOST=$(resolve_peer "$MAC")
            PEER_IP=$(ip neigh show dev "$BAT_IF" 2>/dev/null | grep "$MAC" | awk '{print $1}' | head -n1)
            # TQ = Transmission Quality, batman-adv metric (0-255, higher=better)
            TQ=$(batctl neighbors 2>/dev/null | awk -v mac="$MAC" '$2==mac {print $4; exit}')
            LASTSEEN=$(batctl neighbors 2>/dev/null | awk -v mac="$MAC" '$2==mac {print $3; exit}')
            printf "  %-14s %-16s %-10s %-10s\n" \
                "${HOST:-$MAC}" "${PEER_IP:--}" "${TQ:--}" "${LASTSEEN:--}"
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
        echo "  Not in mesh (batman-adv not active)"
        return
    fi

    local COUNT=0
    while IFS= read -r MAC; do
        COUNT=$((COUNT+1))
        local HOST PEER_IP TQ LASTSEEN
        HOST=$(resolve_peer "$MAC")
        PEER_IP=$(ip neigh show dev "$BAT_IF" 2>/dev/null | grep "$MAC" | awk '{print $1}' | head -n1)
        TQ=$(batctl neighbors 2>/dev/null | awk -v mac="$MAC" '$2==mac {print $4; exit}')
        LASTSEEN=$(batctl neighbors 2>/dev/null | awk -v mac="$MAC" '$2==mac {print $3; exit}')

        echo ""
        echo "  Peer     : ${HOST:-unknown}"
        echo "  MAC      : $MAC"
        echo "  IP       : ${PEER_IP:--}"
        echo "  TQ       : ${TQ:--}  (Transmission Quality 0-255)"
        echo "  Last seen: ${LASTSEEN:--}"
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
        echo "  Not in mesh (batman-adv not active)"
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
        local HOST TQ
        HOST=$(resolve_peer "$MAC")
        TQ=$(batctl neighbors 2>/dev/null | awk -v mac="$MAC" '$2==mac {print $4; exit}')
        echo "    $SELF  <--[TQ:${TQ:--}]-->  $HOST"
    done < <(peer_macs)

    [[ "$COUNT" -eq 0 ]] && echo "    (no direct peers)"

    echo ""
    echo "  Mesh routes (batman-adv originators):"
    local ROUTES=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[0-9a-f]{2}: ]] || continue
        ROUTES=$((ROUTES+1))
        local DEST NEXTHOP
        DEST=$(echo "$line" | awk '{print $1}')
        NEXTHOP=$(echo "$line" | awk '{print $3}')
        local DEST_HOST NEXT_HOST
        DEST_HOST=$(resolve_peer "$DEST")
        NEXT_HOST=$(resolve_peer "$NEXTHOP")
        echo "    ${DEST_HOST:-$DEST}  →  via ${NEXT_HOST:-$NEXTHOP}"
    done < <(batctl o 2>/dev/null)

    [[ "$ROUTES" -eq 0 ]] && echo "    (no originators yet)"
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
        echo "  Not in mesh (batman-adv not active)"
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
        local HOST TQ
        HOST=$(resolve_peer "$MAC")
        TQ=$(batctl neighbors 2>/dev/null | awk -v mac="$MAC" '$2==mac {print $4; exit}')
        if [[ "$i" -eq "$PEERS" ]]; then
            echo "  └── $HOST  (TQ:${TQ:--})"
        else
            echo "  ├── $HOST  (TQ:${TQ:--})"
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
        echo "  Not in mesh (batman-adv not active)"
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
        if ping -c1 -W1 -I "$BAT_IF" "$TARGET" >/dev/null 2>&1; then
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
# ORIGINATORS
# --------------------------------------------------

cmd_originators() {
    echo "================================="
    echo "BirdDog batman-adv Originators"
    echo "================================="
    echo ""
    if ! mesh_joined; then
        echo "  Not in mesh (batman-adv not active)"
        return
    fi
    batctl o 2>/dev/null || echo "  (no originator table yet)"
    echo ""
}

# --------------------------------------------------
# DISPATCH
# --------------------------------------------------

case "$1" in
    status)      cmd_status ;;
    peers)       cmd_peers ;;
    map)         cmd_map ;;
    graph)       cmd_graph ;;
    log)         cmd_log "${2:-30}" ;;
    watch)       cmd_watch "${2:-5}" ;;
    ping)        cmd_ping ;;
    originators) cmd_originators ;;
    ""  | help)
        echo ""
        echo "================================="
        echo "BirdDog Mesh CLI"
        echo "================================="
        echo ""
        echo "  mesh status        mesh health + peer table"
        echo "  mesh peers         detailed batman-adv metrics per peer"
        echo "  mesh map           direct links + originator routes"
        echo "  mesh graph         topology tree"
        echo "  mesh log [N]       last N lines of runtime log (default 30)"
        echo "  mesh watch [N]     live status refresh every N seconds (default 5)"
        echo "  mesh ping          ping all expected mesh nodes"
        echo "  mesh originators   raw batman-adv originator table"
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
GOLDEN_UPDATED=0

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

# Fetch golden image first and flag if it changed
TMP_GI="/tmp/birddog_fetch_gi.$$"
if curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/${REMOTE_COMMIT}/common/golden_image_creation.sh" -o "$TMP_GI" 2>/dev/null; then
    if cmp -s "$TMP_GI" "$BIRDDOG_ROOT/common/golden_image_creation.sh" 2>/dev/null; then
        printf "  %-8s %s\n" "UNCHANGED" "common/golden_image_creation.sh"
    else
        printf "  %-8s %s\n" "UPDATED" "common/golden_image_creation.sh"
        install -m 0755 "$TMP_GI" "$BIRDDOG_ROOT/common/golden_image_creation.sh"
        GOLDEN_UPDATED=1
    fi
else
    printf "  %-8s %s\n" "FAILED" "common/golden_image_creation.sh"
    FETCH_FAILED=1
fi
rm -f "$TMP_GI"
fetch_file common/device_configure.sh       "$BIRDDOG_ROOT/common/device_configure.sh"
fetch_file common/oobe_reset.sh             "$BIRDDOG_ROOT/common/oobe_reset.sh"
fetch_file common/verify_node.sh            "$BIRDDOG_ROOT/common/verify_node.sh"
fetch_file bdm/bdm_AP_setup.sh              "$BIRDDOG_ROOT/bdm/bdm_AP_setup.sh"
fetch_file bdm/bdm_mediamtx_setup.sh        "$BIRDDOG_ROOT/bdm/bdm_mediamtx_setup.sh"
fetch_file bdm/bdm_web_setup.sh             "$BIRDDOG_ROOT/bdm/bdm_web_setup.sh"
fetch_file bdc/bdc_fresh_install_setup.sh   "$BIRDDOG_ROOT/bdc/bdc_fresh_install_setup.sh"

if [[ "$FETCH_FAILED" -eq 1 ]]; then
    echo ""
    echo "ERROR: One or more scripts failed to fetch — aborting"
    echo "       Platform identity not updated"
    exit 1
fi

echo "$REMOTE_COMMIT" > "$COMMIT_FILE"
echo "$BIRDDOG_VERSION" > "$VERSION_FILE"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$BUILD_FILE"

# --------------------------------------------------
# PERMS + CLI + DAEMON (full install only)
# --------------------------------------------------

if [[ "$BIRDDOG_MODE" == "full" ]]; then

echo "[Phase 4] Permissions"

chmod +x "$BIRDDOG_ROOT"/common/*.sh
chmod +x "$BIRDDOG_ROOT"/bdm/*.sh
chmod +x "$BIRDDOG_ROOT"/bdc/*.sh
shopt -s nullglob
for f in "$BIRDDOG_ROOT"/mesh/*.sh; do chmod +x "$f"; done
shopt -u nullglob

# --------------------------------------------------
# CLI + DAEMON
# --------------------------------------------------

echo "[Phase 5] Installing BirdDog CLI and birddog_day daemon"

# ── birddog_day.py ──

cat > /usr/local/bin/birddog_day.py <<'BIRDDOG_DAY'
#!/usr/bin/env python3

# birddog_day — BirdDog hardware status daemon
# Monitors mesh, stream, and camera state and reflects it on LEDs.
# Handles button interactions and role switch detection.
# Runs as birddog_day.service — golden image, role independent.

import RPi.GPIO as GPIO
import time
import subprocess
import os
import json

# ── GPIO pin assignments ──
PIN_LED_BLUE   = 17
PIN_LED_GREEN  = 27
PIN_LED_YELLOW = 22
PIN_LED_RED    = 23
PIN_BUZZER     = 24
PIN_BUTTON     = 25
PIN_SWITCH     = 5   # role switch: open=BDM, closed=BDC

# ── timing ──
LOOP_RATE        = 0.01   # 10ms main loop
STATE_INTERVAL   = 3.0    # systemd checks every 3 seconds
BLINK_SLOW       = 0.5    # 1Hz  — joining mesh / stream restarting
BLINK_FAST       = 0.125  # 4Hz  — in mesh no peer / mediamtx up no streams
PRESS_ROLL_CALL  = 4.0    # 4s hold — LED roll call
LONG_PRESS_TIME  = 10.0   # 10s hold — shutdown
SOS_INTERVAL     = 30.0   # seconds between periodic SOS on mismatch

# ── IPC ──
# External processes drop command files into IPC_DIR.
# birddog_day processes and deletes them each main loop iteration.
# Command files are named cmd.<action> e.g. cmd.beep_role
IPC_DIR = "/run/birddog"

# ── state ──
led_blue_blink       = 0
led_green_blink      = 0   # 0=off 1=slow 2=fast 3=solid
last_state_check     = 0
last_blink_slow      = 0
last_blink_fast      = 0
blink_phase_slow     = False
blink_phase_fast     = False
button_press_time    = None
roll_call_fired      = False
last_sos_time        = 0
current_mismatch     = False

def setup():
    GPIO.setmode(GPIO.BCM)
    GPIO.setwarnings(False)
    for pin in [PIN_LED_BLUE, PIN_LED_GREEN, PIN_LED_YELLOW, PIN_LED_RED, PIN_BUZZER]:
        GPIO.setup(pin, GPIO.OUT)
        GPIO.output(pin, GPIO.LOW)
    GPIO.setup(PIN_BUTTON, GPIO.IN, pull_up_down=GPIO.PUD_UP)
    GPIO.setup(PIN_SWITCH, GPIO.IN, pull_up_down=GPIO.PUD_UP)

def all_leds_off():
    for pin in [PIN_LED_BLUE, PIN_LED_GREEN, PIN_LED_YELLOW, PIN_LED_RED]:
        GPIO.output(pin, GPIO.LOW)

def beep(pattern):
    for on_t, off_t in pattern:
        GPIO.output(PIN_BUZZER, GPIO.HIGH)
        time.sleep(on_t)
        GPIO.output(PIN_BUZZER, GPIO.LOW)
        if off_t > 0:
            time.sleep(off_t)

def boot_beep():
    beep([(0.1, 0.15), (0.1, 0)])

def shutdown_beep():
    beep([(1.0, 0)])

def role_beep():
    beep([(0.8, 0)])

def sos_beep():
    dot = 0.1
    dash = 0.3
    gap = 0.1
    letter_gap = 0.3
    word_gap = 0.6
    sos = [
        (dot, gap), (dot, gap), (dot, letter_gap),
        (dash, gap), (dash, gap), (dash, letter_gap),
        (dot, gap), (dot, gap), (dot, word_gap),
    ]
    beep(sos)
    time.sleep(0.3)
    beep(sos)

def led_flash(pin, times=3, on_time=0.1, off_time=0.1):
    for _ in range(times):
        GPIO.output(pin, GPIO.HIGH)
        time.sleep(on_time)
        GPIO.output(pin, GPIO.LOW)
        time.sleep(off_time)

def status_roll_call():
    saved = {}
    for pin in [PIN_LED_BLUE, PIN_LED_GREEN, PIN_LED_YELLOW, PIN_LED_RED]:
        saved[pin] = GPIO.input(pin)

    boot_beep()
    time.sleep(0.1)

    all_leds_off()
    time.sleep(0.1)

    led_flash(PIN_LED_BLUE)
    time.sleep(0.1)
    led_flash(PIN_LED_GREEN)
    time.sleep(0.1)
    led_flash(PIN_LED_YELLOW)
    time.sleep(0.1)
    led_flash(PIN_LED_RED)
    time.sleep(0.1)

    boot_beep()

    for pin, state in saved.items():
        GPIO.output(pin, state)

def read_role():
    return "bdm" if GPIO.input(PIN_SWITCH) == GPIO.HIGH else "bdc"

def committed_role():
    try:
        host = open('/etc/hostname').read().strip()
        if host.startswith('bdm-'):
            return 'bdm'
        elif host.startswith('bdc-'):
            return 'bdc'
    except Exception:
        pass
    return None

def is_bootstrap():
    try:
        host = open('/etc/hostname').read().strip()
        return not (host.startswith('bdm-') or host.startswith('bdc-'))
    except Exception:
        return True

def service_active(name):
    try:
        result = subprocess.run(
            ["systemctl", "is-active", name],
            capture_output=True, text=True, timeout=3
        )
        return result.stdout.strip() == "active"
    except Exception:
        return False

def service_activating(name):
    try:
        result = subprocess.run(
            ["systemctl", "is-active", name],
            capture_output=True, text=True, timeout=3
        )
        return result.stdout.strip() == "activating"
    except Exception:
        return False

def mesh_active():
    # batman-adv mesh is up when bat0 exists and wlan_mesh_5 is attached to it
    try:
        bat0_exists = os.path.exists("/sys/class/net/bat0")
        if not bat0_exists:
            return False
        result = subprocess.run(
            ["batctl", "if"],
            capture_output=True, text=True, timeout=3
        )
        return "wlan_mesh_5" in result.stdout
    except Exception:
        return False

def mesh_has_peer():
    # Check batman-adv neighbor table for any direct peers
    try:
        result = subprocess.run(
            ["batctl", "neighbors"],
            capture_output=True, text=True, timeout=3
        )
        lines = [l for l in result.stdout.splitlines()
                 if l and not l.startswith("[B.A.T") and not l.startswith("IF")]
        return len(lines) > 0
    except Exception:
        return False

def camera_ok():
    return os.path.exists("/dev/video0") or os.path.exists("/dev/v4l/by-id")

def mediamtx_stream_count():
    # Query mediamtx API for active stream count
    # Returns (service_running, stream_count)
    try:
        result = subprocess.run(
            ["curl", "-s", "--connect-timeout", "1",
             "http://localhost:9997/v3/paths/list"],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode != 0:
            return False, 0
        data = json.loads(result.stdout)
        count = sum(1 for item in data.get("items", []) if item.get("ready"))
        return True, count
    except Exception:
        return False, 0

def check_state():
    global led_blue_blink, led_green_blink, current_mismatch, last_sos_time

    # ── yellow: bootstrap / mismatch ──
    bootstrap = is_bootstrap()
    role_sw   = read_role()
    role_cfg  = committed_role()
    mismatch  = (not bootstrap) and (role_cfg is not None) and (role_sw != role_cfg)
    current_mismatch = mismatch

    if bootstrap or mismatch:
        GPIO.output(PIN_LED_YELLOW, GPIO.HIGH)
    else:
        GPIO.output(PIN_LED_YELLOW, GPIO.LOW)

    # ── periodic SOS on mismatch ──
    now = time.time()
    if mismatch and (now - last_sos_time >= SOS_INTERVAL):
        last_sos_time = now
        sos_beep()

    # ── blue: mesh (batman-adv via bat0) ──
    mesh_svc  = service_active("birddog-mesh")
    bat0_up   = os.path.exists("/sys/class/net/bat0")
    joined    = mesh_active()
    has_peer  = mesh_has_peer()

    if not mesh_svc or not bat0_up:
        led_blue_blink = 0
        GPIO.output(PIN_LED_BLUE, GPIO.LOW)
    elif not joined:
        led_blue_blink = 1   # slow blink — joining
    elif not has_peer:
        led_blue_blink = 2   # fast blink — no peer
    else:
        led_blue_blink = 3   # solid — joined with peer
        GPIO.output(PIN_LED_BLUE, GPIO.HIGH)

    # ── green: role-dependent ──
    role = committed_role() or read_role()

    if role == "bdm":
        # BDM: reflect mediamtx state and stream count
        mtx_running, stream_count = mediamtx_stream_count()
        if not mtx_running:
            led_green_blink = 0
            GPIO.output(PIN_LED_GREEN, GPIO.LOW)
        elif stream_count == 0:
            # mediamtx up, no active streams — fast blink (waiting for cameras)
            led_green_blink = 2
        else:
            # mediamtx up with active streams — solid
            led_green_blink = 0
            GPIO.output(PIN_LED_GREEN, GPIO.HIGH)
    else:
        # BDC: reflect birddog-stream service state
        stream_active     = service_active("birddog-stream")
        stream_activating = service_activating("birddog-stream")

        if stream_activating:
            led_green_blink = 1   # slow blink — restarting
        elif stream_active:
            led_green_blink = 0
            GPIO.output(PIN_LED_GREEN, GPIO.HIGH)
        else:
            led_green_blink = 0
            GPIO.output(PIN_LED_GREEN, GPIO.LOW)

    # ── red: camera ──
    # BDC: camera is required — red if absent or failing
    # BDM: camera not required — red only if /dev/video0 exists but camera_ok() fails
    #      indicating a hardware fault rather than simply no camera attached
    cam = camera_ok()
    if role == "bdc":
        GPIO.output(PIN_LED_RED, GPIO.LOW if cam else GPIO.HIGH)
    else:
        cam_present = os.path.exists("/dev/video0")
        if cam_present and not cam:
            GPIO.output(PIN_LED_RED, GPIO.HIGH)
        else:
            GPIO.output(PIN_LED_RED, GPIO.LOW)

def update_blink(now):
    global last_blink_slow, last_blink_fast, blink_phase_slow, blink_phase_fast

    if now - last_blink_slow >= BLINK_SLOW:
        blink_phase_slow = not blink_phase_slow
        last_blink_slow = now
        if led_blue_blink == 1:
            GPIO.output(PIN_LED_BLUE, GPIO.HIGH if blink_phase_slow else GPIO.LOW)
        if led_green_blink == 1:
            GPIO.output(PIN_LED_GREEN, GPIO.HIGH if blink_phase_slow else GPIO.LOW)

    if now - last_blink_fast >= BLINK_FAST:
        blink_phase_fast = not blink_phase_fast
        last_blink_fast = now
        if led_blue_blink == 2:
            GPIO.output(PIN_LED_BLUE, GPIO.HIGH if blink_phase_fast else GPIO.LOW)
        if led_green_blink == 2:
            GPIO.output(PIN_LED_GREEN, GPIO.HIGH if blink_phase_fast else GPIO.LOW)

def check_button(now):
    global button_press_time, roll_call_fired
    pressed = GPIO.input(PIN_BUTTON) == GPIO.LOW

    if pressed and button_press_time is None:
        button_press_time = now
        roll_call_fired = False

    elif pressed and button_press_time is not None:
        held = now - button_press_time

        if held >= PRESS_ROLL_CALL and not roll_call_fired:
            status_roll_call()
            roll_call_fired = True

        if held >= LONG_PRESS_TIME:
            all_leds_off()
            GPIO.output(PIN_LED_RED, GPIO.HIGH)
            shutdown_beep()
            GPIO.cleanup()
            os.system("sudo poweroff")

    elif not pressed and button_press_time is not None:
        held = now - button_press_time
        if held >= 0.05 and held < PRESS_ROLL_CALL:
            # short press — alive confirmation beep
            beep([(2.0, 0)])
        button_press_time = None
        roll_call_fired = False

def boot_sequence():
    global last_sos_time
    role_sw   = read_role()
    bootstrap = is_bootstrap()
    role_cfg  = committed_role()
    mismatch  = (not bootstrap) and (role_cfg is not None) and (role_sw != role_cfg)

    if mismatch:
        GPIO.output(PIN_LED_YELLOW, GPIO.HIGH)
        sos_beep()
        sos_beep()
        last_sos_time = time.time()  # reset timer after boot SOS x2
    elif bootstrap:
        GPIO.output(PIN_LED_YELLOW, GPIO.HIGH)
        boot_beep()
    else:
        boot_beep()
        time.sleep(0.3)
        role_beep()

def check_ipc():
    try:
        if not os.path.isdir(IPC_DIR):
            return
        for fname in os.listdir(IPC_DIR):
            if not fname.startswith("cmd."):
                continue
            fpath = os.path.join(IPC_DIR, fname)
            action = fname[4:]  # strip "cmd."
            try:
                os.remove(fpath)
            except Exception:
                continue
            if action == "beep_role":
                boot_beep()
                time.sleep(0.3)
                role_beep()
            elif action == "beep_boot":
                boot_beep()
            elif action == "beep_sos":
                sos_beep()
            elif action == "roll_call":
                status_roll_call()
    except Exception:
        pass

def main():
    global last_state_check
    os.makedirs(IPC_DIR, exist_ok=True)
    setup()
    time.sleep(3)  # wait for hostname to settle before reading role
    boot_sequence()
    check_state()
    last_state_check = time.time()

    while True:
        now = time.time()
        check_ipc()
        check_button(now)
        update_blink(now)
        if now - last_state_check >= STATE_INTERVAL:
            check_state()
            last_state_check = now
        time.sleep(LOOP_RATE)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    finally:
        GPIO.cleanup()

BIRDDOG_DAY

chmod +x /usr/local/bin/birddog_day.py
echo "  birddog_day.py installed → /usr/local/bin/birddog_day.py"

# ── birddog_day.service ──

cat > /etc/systemd/system/birddog_day.service <<'BIRDDOG_DAY_SVC'
[Unit]
Description=BirdDog Hardware Status Daemon
After=multi-user.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/birddog_day.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
BIRDDOG_DAY_SVC

systemctl daemon-reload
systemctl enable birddog_day.service
echo "  birddog_day.service installed and enabled"

# ── birddog-mesh-join.sh + service ──
# batman-adv mesh runtime. Uses 802.11s Mesh Point mode as the transport
# layer on wlan_mesh_5, with batman-adv owning all routing via bat0.
# mesh_fwding=0 disables 802.11s forwarding so batman-adv is the sole
# router — this is intentional and required for correct batman-adv operation.

LOG_DIR="/opt/birddog/mesh"
mkdir -p "$LOG_DIR"

cat > /usr/local/bin/birddog-mesh-join.sh <<'MESH_RUNTIME'
#!/bin/bash

# BirdDog Mesh Runtime — batman-adv
# Manages batman-adv mesh on wlan_mesh_5 (MT7612U, 5 GHz ch36).
# batman-adv presents bat0 as the L3 mesh interface.
# IP is read from /opt/birddog/mesh/mesh.conf at startup.
# Falls back to random bootstrap IP (10.10.20.231-254) if unconfigured.
# Runs as birddog-mesh.service (systemd).

LOG="/opt/birddog/mesh/mesh_runtime.log"
MESH_CONF="/opt/birddog/mesh/mesh.conf"
MESH_IF="wlan_mesh_5"
BAT_IF="bat0"
MESH_ID="birddog-mesh"
FREQ=5180   # channel 36, 5 GHz

if [[ -f "$MESH_CONF" ]]; then
    source "$MESH_CONF"
else
    OCTET=$(( RANDOM % 24 + 231 ))
    MESH_IP="10.10.20.${OCTET}/24"
fi

MESH_IP="${MESH_IP:-10.10.20.254/24}"

STATE="INIT"
LAST_PEER_TIME=0
LAST_JOIN_TIME=0

JOIN_COOLDOWN=15
SUSPECT_THRESHOLD=45
RECOVERY_THRESHOLD=90

log() {
    echo "[$(date '+%H:%M:%S')] [mesh] $1" >> "$LOG"
}

log_state() {
    log "STATE → $1"
}

interface_exists() {
    ip link show "$MESH_IF" >/dev/null 2>&1
}

mesh_active() {
    # batman-adv is up when bat0 exists and wlan_mesh_5 is attached
    ip link show "$BAT_IF" >/dev/null 2>&1 && \
        batctl if 2>/dev/null | grep -q "$MESH_IF"
}

assign_ip_if_missing() {
    if ! ip addr show "$BAT_IF" 2>/dev/null | grep -q "${MESH_IP%/*}"; then
        ip addr replace "$MESH_IP" dev "$BAT_IF" >> "$LOG" 2>&1 || true
        log "bat0 IP restored: $MESH_IP"
    fi
}

teardown() {
    log "Tearing down..."
    ip link set "$BAT_IF" down 2>/dev/null || true
    batctl if del "$MESH_IF" 2>/dev/null || true
    iw dev "$MESH_IF" mesh leave 2>/dev/null || true
    ip link set "$MESH_IF" down 2>/dev/null || true
}

normalize_and_join() {
    local NOW
    NOW=$(date +%s)

    if (( NOW - LAST_JOIN_TIME < JOIN_COOLDOWN )); then
        log "join cooldown active — skipping"
        return
    fi

    log "normalize + join attempt"

    modprobe batman-adv 2>/dev/null || true

    ip link set "$MESH_IF" down >> "$LOG" 2>&1 || true
    sleep 1

    # Set interface to 802.11s Mesh Point mode — this is the transport layer
    # batman-adv rides on top of. mesh_fwding=0 is set after join to ensure
    # batman-adv owns all routing, not the 802.11s layer.
    iw dev "$MESH_IF" set type mp >> "$LOG" 2>&1 || {
        log "ERROR: could not set $MESH_IF to mesh point mode"
        return 1
    }

    iw dev "$MESH_IF" set power_save off >> "$LOG" 2>&1 || true
    ip link set "$MESH_IF" up >> "$LOG" 2>&1 || true
    sleep 1

    iw dev "$MESH_IF" mesh join "$MESH_ID" freq "$FREQ" HT20 >> "$LOG" 2>&1 || {
        log "mesh join failed — will retry"
        sleep $(( RANDOM % 4 + 2 ))
        LAST_JOIN_TIME=$(date +%s)
        return 1
    }

    # Disable 802.11s forwarding — batman-adv must be the sole router
    iw dev "$MESH_IF" set mesh_param mesh_fwding 0 >> "$LOG" 2>&1 || true

    # Attach wlan_mesh_5 to batman-adv and bring bat0 up
    batctl if add "$MESH_IF" >> "$LOG" 2>&1 || true
    ip link set "$BAT_IF" up >> "$LOG" 2>&1 || true
    ip addr replace "$MESH_IP" dev "$BAT_IF" >> "$LOG" 2>&1 || true

    # MTU sizing — 802.11s adds overhead; wlan_mesh_5 gets 1532 so bat0
    # can present standard 1500 MTU to upper layers
    ip link set "$MESH_IF" mtu 1532 >> "$LOG" 2>&1 || true
    ip link set "$BAT_IF" mtu 1500 >> "$LOG" 2>&1 || true

    LAST_JOIN_TIME=$(date +%s)
    log "join successful — bat0 IP: $MESH_IP"
    return 0
}

check_for_peer() {
    local PEER_FOUND=0

    # Check batman-adv neighbor table for any direct peers
    local NEIGH
    NEIGH=$(batctl neighbors 2>/dev/null | awk 'NR>2 && /[0-9a-f:]/{print $2}' | head -1)
    if [[ -n "$NEIGH" ]]; then
        PEER_FOUND=1
    else
        # Probe nearby mesh IPs to stimulate ARP/neighbor discovery
        local OWN_OCTET
        OWN_OCTET=$(echo "$MESH_IP" | cut -d/ -f1 | awk -F. '{print $4}')
        local OWN_NUM=$(( OWN_OCTET / 10 ))

        for delta in -1 1 -2 2 -3 3; do
            local SLOT=$(( OWN_NUM + delta ))
            [[ "$SLOT" -lt 1 || "$SLOT" -gt 25 ]] && continue
            local TARGET="10.10.20.$((SLOT * 10))"
            ping -c1 -W1 "$TARGET" >/dev/null 2>&1 || true
            NEIGH=$(batctl neighbors 2>/dev/null | awk 'NR>2 && /[0-9a-f:]/{print $2}' | head -1)
            if [[ -n "$NEIGH" ]]; then
                PEER_FOUND=1
                break
            fi
        done
    fi

    echo "$PEER_FOUND"
}

log "================================="
log "Mesh runtime start"
log "Hostname : $(hostname)"
log "Mesh IP  : $MESH_IP"
log "Interface: $MESH_IF → $BAT_IF"
log "Freq     : $FREQ MHz (ch36)"

sleep 5

STATE="WAIT_INTERFACE"
log_state "$STATE"

while true; do

    if ! interface_exists; then
        if [[ "$STATE" != "WAIT_INTERFACE" ]]; then
            STATE="WAIT_INTERFACE"
            log_state "$STATE"
        fi
        sleep 2
        continue
    fi

    if [[ "$STATE" == "WAIT_INTERFACE" ]]; then
        STATE="NORMALIZE"
        log_state "$STATE"
        normalize_and_join || true
        STATE="CONVERGING"
        log_state "$STATE"
    fi

    if ! mesh_active; then
        log "batman-adv mesh lost"
        teardown
        STATE="RECOVERY"
        log_state "$STATE"
    fi

    assign_ip_if_missing

    PEER_FOUND=$(check_for_peer)

    NOW=$(date +%s)

    if [[ "$PEER_FOUND" -eq 1 && "$LAST_PEER_TIME" -eq 0 ]]; then
        LAST_PEER_TIME=$NOW
    fi

    DELTA=0
    [[ "$LAST_PEER_TIME" -gt 0 ]] && DELTA=$(( NOW - LAST_PEER_TIME ))

    if [[ "$PEER_FOUND" -eq 1 ]]; then
        LAST_PEER_TIME=$NOW
    fi

    case "$STATE" in

        CONVERGING)
            if [[ "$PEER_FOUND" -eq 1 ]]; then
                STATE="STEADY"
                log_state "$STATE"
            fi
            ;;

        STEADY)
            if (( DELTA > SUSPECT_THRESHOLD )); then
                STATE="SUSPECT"
                log_state "$STATE"
            fi
            ;;

        SUSPECT)
            if [[ "$PEER_FOUND" -eq 1 ]]; then
                STATE="STEADY"
                log_state "$STATE"
            elif (( DELTA > RECOVERY_THRESHOLD )); then
                STATE="RECOVERY"
                log_state "$STATE"
            fi
            ;;

        RECOVERY)
            teardown
            sleep 2
            normalize_and_join || true
            STATE="CONVERGING"
            log_state "$STATE"
            ;;

    esac

    case "$STATE" in
        CONVERGING) sleep 2  ;;
        SUSPECT)    sleep 5  ;;
        STEADY)
            # Keep bat0 neighbors alive with periodic pings
            while IFS= read -r MAC; do
                [[ -z "$MAC" ]] && continue
                PEER_IP=$(ip neigh show dev "$BAT_IF" 2>/dev/null | awk -v mac="$MAC" '$0 ~ mac {print $1; exit}')
                [[ -n "$PEER_IP" ]] && ping -c1 -W1 "$PEER_IP" >/dev/null 2>&1 || true
            done < <(batctl neighbors 2>/dev/null | awk 'NR>2 && /[0-9a-f:]/{print $2}')
            sleep $(( 35 + RANDOM % 10 ))
            ;;
        *)          sleep 5  ;;
    esac

done
MESH_RUNTIME

chmod +x /usr/local/bin/birddog-mesh-join.sh
echo "  birddog-mesh-join.sh installed → /usr/local/bin/birddog-mesh-join.sh"

# ── birddog-mavlink-bridge.sh ──

cat > /usr/local/bin/birddog-mavlink-bridge.sh <<'MAVLINK_BRIDGE'
#!/bin/bash

# BirdDog MAVLink Bridge
# Connects wlan0 (onboard brcmfmac) to ELRS TX backpack AP and bridges
# MAVLink telemetry to Mission Planner via the BirdDog AP (wlan_ap).
# wlan0 is blocked by default and only unblocked for the duration of
# this session. Reboot restores the blocked state.

ELRS_PASSWORD="expresslrs"
ELRS_SSID_BASE="ExpressLRS TX Backpack"
MAVLINK_CONF="/opt/birddog/bdm/mavlink.conf"

if [[ "$EUID" -ne 0 ]]; then
    exec sudo bash /usr/local/bin/birddog-mavlink-bridge.sh "$@"
fi

echo ""
echo "================================="
echo "BirdDog MAVLink Bridge"
echo "================================="
echo ""
echo "  The ELRS TX backpack broadcasts MAVLink telemetry over WiFi."
echo "  This bridges wlan0 to the BirdDog AP so Mission Planner"
echo "  on the wlan_ap network receives drone telemetry on UDP 14550."
echo ""

teardown_mavlink() {
    if pgrep -f "mavproxy" >/dev/null 2>&1; then
        echo "  Stopping existing MAVProxy session..."
        pkill -f "mavproxy" 2>/dev/null || true
        sleep 1
    fi
    # Kill any stale wpa_supplicant processes — broad kill ensures no
    # leftover association state blocks the next connect attempt
    pkill -f "wpa_supplicant" 2>/dev/null || true
    pkill -f "dhcpcd" 2>/dev/null || true
    ip link set wlan0 down 2>/dev/null || true
    sleep 1
    WLAN0_RFKILL_IDX=$(cat /sys/class/net/wlan0/phy80211/rfkill*/index 2>/dev/null)
    if [[ -n "$WLAN0_RFKILL_IDX" ]]; then
        # Full rfkill cycle — block then unblock forces driver reset,
        # clearing any stale association state that ip link down alone
        # does not clear
        echo 1 | tee "/sys/class/rfkill/rfkill${WLAN0_RFKILL_IDX}/soft" >/dev/null 2>&1 || true
        sleep 1
        echo 0 | tee "/sys/class/rfkill/rfkill${WLAN0_RFKILL_IDX}/soft" >/dev/null 2>&1 || true
        sleep 1
    fi
    ip link set wlan0 down 2>/dev/null || true
    rm -f "$MAVLINK_CONF" 2>/dev/null || true
}

teardown_mavlink

WLAN0_RFKILL_IDX=$(cat /sys/class/net/wlan0/phy80211/rfkill*/index 2>/dev/null)
if [[ -n "$WLAN0_RFKILL_IDX" ]]; then
    # rfkill userspace tool not available — unblock via sysfs directly
    echo 0 | tee "/sys/class/rfkill/rfkill${WLAN0_RFKILL_IDX}/soft" >/dev/null 2>&1 || true
fi
sleep 1
sudo ip link set wlan0 up 2>/dev/null || true
sleep 5

block_wlan0() {
    if [[ -n "$WLAN0_RFKILL_IDX" ]]; then
        # rfkill userspace tool not available — block via sysfs directly
        echo 1 | tee "/sys/class/rfkill/rfkill${WLAN0_RFKILL_IDX}/soft" >/dev/null 2>&1 || true
    fi
    ip link set wlan0 down 2>/dev/null || true
}

do_scan() {
    echo "  Scanning for ELRS backpack..."
    DETECTED_SSID=$(iw dev wlan0 scan 2>/dev/null \
        | grep -oP "(?<=SSID: )${ELRS_SSID_BASE} [0-9a-fA-F]{6}" \
        | head -1)
}

do_scan

while true; do
    if [[ -n "$DETECTED_SSID" ]]; then
        echo "  Found : $DETECTED_SSID"
        echo ""
        echo "  [Y]    — connect to $DETECTED_SSID"
        echo "  [R]    — rescan"
        echo "  [UID]  — enter a different 6-digit UID"
        echo "  [SSID] — enter full network name manually"
        echo "  [X]    — cancel"
        echo ""
        VALID_CHOICES="Y|R|UID|SSID|X"
    else
        echo "  No ELRS backpack detected"
        echo ""
        echo "  [R]    — rescan"
        echo "  [UID]  — enter 6-digit code from backpack"
        echo "  [SSID] — enter full network name manually"
        echo "  [X]    — cancel"
        echo ""
        VALID_CHOICES="R|UID|SSID|X"
    fi

    read -r -p "  Choice: " MODE_INPUT
    if [[ ! "$MODE_INPUT" =~ ^(${VALID_CHOICES})$ ]]; then
        echo "  Invalid — enter one of: ${VALID_CHOICES//|/ }"
        continue
    fi

    if [[ "$MODE_INPUT" == "R" ]]; then
        do_scan
        continue
    fi



    break
done

if [[ "$MODE_INPUT" == "X" ]]; then
    echo "  Cancelled."
    block_wlan0
    exit 0
elif [[ "$MODE_INPUT" == "Y" ]]; then
    ELRS_SSID="$DETECTED_SSID"
    echo "  SSID : $ELRS_SSID"
elif [[ "$MODE_INPUT" == "UID" ]]; then
    while true; do
        read -r -p "  Enter 6-digit UID: " MAVLINK_INPUT
        [[ "$MAVLINK_INPUT" =~ ^[0-9a-fA-F]{6}$ ]] && break
        echo "  Invalid — must be exactly 6 hex characters (e.g. a1b2c3)"
    done
    ELRS_SSID="${ELRS_SSID_BASE} ${MAVLINK_INPUT}"
    echo "  SSID : $ELRS_SSID"
else
    read -r -p "  Enter full SSID: " MAVLINK_INPUT
    ELRS_SSID="$MAVLINK_INPUT"
    echo "  SSID : $ELRS_SSID"
fi

WPA_CONF="/tmp/birddog_elrs_wpa.conf"
cat > "$WPA_CONF" << EOF
ctrl_interface=/tmp/birddog_wpa_ctrl
update_config=0
p2p_disabled=1
device_type=1-0050F204-1

network={
    ssid="${ELRS_SSID}"
    psk="${ELRS_PASSWORD}"
    key_mgmt=WPA-PSK
    proto=RSN
    pairwise=CCMP TKIP
    group=TKIP
}
EOF

pkill -f "wpa_supplicant.*birddog_elrs" 2>/dev/null || true
rm -f /tmp/birddog_elrs_wpa.pid /tmp/birddog_wpa_ctrl/wlan0 2>/dev/null || true
mkdir -p /tmp/birddog_wpa_ctrl
sleep 1

ip link set wlan0 down 2>/dev/null || true
sleep 1
ip link set wlan0 up 2>/dev/null || true
sleep 1

echo "  Connecting to $ELRS_SSID ..."
wpa_supplicant -B -i wlan0 -c "$WPA_CONF" -P /tmp/birddog_elrs_wpa.pid -C /tmp/birddog_wpa_ctrl 2>/dev/null || true

killall dhcpcd 2>/dev/null || true
sleep 1
dhcpcd wlan0 -t 30 --nohook resolv.conf 2>/dev/null || true
killall dhcpcd 2>/dev/null || true

WLAN0_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet )[^/]+' | grep -v '^169\.254\.' | head -1)

if [[ -z "$WLAN0_IP" ]]; then
    echo ""
    echo "  Could not connect to $ELRS_SSID"
    echo "  Check UID/SSID and try again — reboot to reset wlan0"
    exit 1
fi

echo "  Connected — wlan0 IP: $WLAN0_IP"

ip route del default dev wlan0 2>/dev/null || true
echo "nameserver 8.8.8.8" > /etc/resolv.conf

mkdir -p /opt/birddog/bdm
cat > "$MAVLINK_CONF" << EOF
ELRS_SSID="${ELRS_SSID}"
WLAN0_IP="${WLAN0_IP}"
MAVLINK_ACTIVE=1
EOF

echo ""
echo "================================="
echo "MAVLink Bridge Active"
echo "================================="
echo "  wlan0    : $WLAN0_IP (ELRS backpack)"
echo "  wlan_ap  : 10.10.10.1 (BirdDog AP)"
echo "  Action   : Connect Mission Planner to BirdDog AP → UDP 14550"
echo "  Note     : MAVProxy starting now — ensure MP is listening"
echo "================================="
echo ""

MAVLINK_LOG="/opt/birddog/logs/mavlink.log"
mkdir -p /opt/birddog/logs
# Create log with open permissions so MAVProxy can write to it
# when launched as a background process via sudo
touch "$MAVLINK_LOG" && chmod 644 "$MAVLINK_LOG"
echo "--- MAVLink Bridge started $(date) ---" > "$MAVLINK_LOG"
# --heartbeat-rate=1 — sends heartbeats at 1 Hz to claim and maintain
# the GCS session with the ELRS backpack. The backpack only pushes
# telemetry to an active GCS; without consistent heartbeats it ignores
# udpin listeners and never sends data.
cd /tmp && /usr/local/bin/mavproxy.py --master=udpin:0.0.0.0:14550 \
    --out=udpout:10.10.10.105:14550 \
    --non-interactive \
    --heartbeat-rate=1 \
    --default-modules="" </dev/null >> "$MAVLINK_LOG" 2>&1 &

sleep 3

if pgrep -f "mavproxy" >/dev/null; then
    echo "  MAVProxy running — telemetry broadcasting to BirdDog AP"
    echo "  Log : $MAVLINK_LOG"
else
    echo "  WARNING: MAVProxy failed to start"
    echo "  Check log: $MAVLINK_LOG"
    echo "  Try manually: cd /tmp && sudo mavproxy.py --master=udpin:0.0.0.0:14550 --out=udpout:10.10.10.105:14550 --heartbeat-rate=1 --non-interactive --default-modules=\"\""
fi
MAVLINK_BRIDGE

chmod +x /usr/local/bin/birddog-mavlink-bridge.sh
echo "  birddog-mavlink-bridge.sh installed → /usr/local/bin/birddog-mavlink-bridge.sh"

cat > /etc/systemd/system/birddog-mesh.service << 'MESH_SVC'
[Unit]
Description=BirdDog Mesh Runtime
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/birddog-mesh-join.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
MESH_SVC

systemctl daemon-reload
systemctl enable birddog-mesh.service
echo "  birddog-mesh.service installed and enabled"

# ── BirdDog ASCII art ──

cat > /usr/local/bin/birddog_art <<'BIRDDOG_ART'
oooooooooo.   o8o                 .o8  oooooooooo.
`888'   `Y8b  `"'                "888  `888'   `Y8b
 888     888 oooo  oooo d8b  .oooo888   888      888  .ooooo.   .oooooooo
 888oooo888' `888  `888""8P d88' `888   888oooo888' d88' `88b 888' `88b
 888    `88b  888   888     888   888   888    `88b 888   888 888   888
 888    .88P  888   888     888   888   888     d88' 888   888 `88bod8P'
o888bood8P'  o888o d888b    `Y8bod88P" o888bood8P'   `Y8bod8P' `8oooooo.
                                                               d"     YD
                                                               "Y88888P'
BIRDDOG_ART

echo "  birddog_art installed → /usr/local/bin/birddog_art"

# ── BirdDog CLI ──

BIRDDOG_CLI="/usr/local/bin/birddog"

cat > "$BIRDDOG_CLI" <<'BIRDDOG_EOF'
#!/bin/bash
BIRDDOG_ROOT="/opt/birddog"

case "$1" in
    install)    exec sudo bash "$BIRDDOG_ROOT/common/golden_image_creation.sh" ;;
    update)     exec sudo BIRDDOG_MODE="refresh" bash "$BIRDDOG_ROOT/common/golden_image_creation.sh" ;;
    configure)  exec sudo bash "$BIRDDOG_ROOT/common/device_configure.sh" ;;
    reset)      exec sudo bash "$BIRDDOG_ROOT/common/oobe_reset.sh" ;;
    verify)     exec sudo bash "$BIRDDOG_ROOT/common/verify_node.sh" ;;
    radios)
        echo "Radio layout:"
        for IFACE in wlan0 wlan_mesh_5 wlan_ap; do
            if ip link show "$IFACE" >/dev/null 2>&1; then
                DRV=$(readlink /sys/class/net/$IFACE/device/driver 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
                MODE=$(iw dev "$IFACE" info 2>/dev/null | awk '/type/ {print $2}' || echo "unknown")
                STATE=$(ip link show "$IFACE" | grep -oP '(?<=state )\w+' || echo "unknown")
                printf "  %-14s driver=%-12s mode=%-10s state=%s\n" "$IFACE" "$DRV" "$MODE" "$STATE"
            fi
        done
        # Show bat0 separately — virtual interface, not a physical radio
        if ip link show bat0 >/dev/null 2>&1; then
            BAT_IP=$(ip -4 addr show bat0 2>/dev/null | grep -oP '(?<=inet )[^/]+' | head -1)
            PEERS=$(batctl neighbors 2>/dev/null | awk 'NR>2 && /[0-9a-f:]/{count++} END{print count+0}')
            printf "  %-14s batman-adv virtual interface — IP: %s  peers: %s\n" "bat0" "${BAT_IP:--}" "$PEERS"
        fi
        ;;
    version)
        VERSION=$(cat "$BIRDDOG_ROOT/version/VERSION" 2>/dev/null || echo "unknown")
        COMMIT=$(cat "$BIRDDOG_ROOT/version/COMMIT" 2>/dev/null || echo "unknown")
        BUILD=$(cat "$BIRDDOG_ROOT/version/BUILD" 2>/dev/null || echo "unknown")
        echo "BirdDog v${VERSION}"
        echo "  Commit : $COMMIT"
        echo "  Built  : $BUILD"
        echo "  Host   : $(hostname)"
        ;;
    rocks)
        cat /usr/local/bin/birddog_art
        ;;
    status)
        HOST=$(hostname)
        ROLE="unknown"
        [[ "$HOST" =~ ^bdm-[0-9]{2}$ ]] && ROLE="BDM"
        [[ "$HOST" =~ ^bdc-[0-9]{2}$ ]] && ROLE="BDC"
        COMMIT=$(cat "$BIRDDOG_ROOT/version/COMMIT" 2>/dev/null || echo "unknown")
        echo ""
        echo "================================="
        echo "BirdDog Status — $HOST"
        echo "================================="
        echo "  Role     : $ROLE"
        MESH_SVC=$(systemctl is-active birddog-mesh 2>/dev/null)
        PEERS=$(batctl neighbors 2>/dev/null | awk 'NR>2 && /[0-9a-f:]/{count++} END{print count+0}')
        MESH_IP=$(ip -4 addr show bat0 2>/dev/null | grep -oP "(?<=inet )[^/]+" | head -1)
        if [[ "$MESH_SVC" == "active" ]]; then
            echo "  Mesh     : joined (${PEERS} peers) — ${MESH_IP:-no IP}"
        else
            echo "  Mesh     : down"
        fi
        if [[ "$ROLE" == "BDM" ]]; then
            MEDIAMTX=$(systemctl is-active mediamtx 2>/dev/null)
            echo "  MediaMTX : $MEDIAMTX"
            if [[ "$MEDIAMTX" == "active" ]]; then
                STREAM_JSON=$(curl -s --connect-timeout 2 http://localhost:9997/v3/paths/list 2>/dev/null)
                LIVE_COUNT=$(echo "$STREAM_JSON" | grep -o '"ready":true' | wc -l | tr -d ' ')
                LIVE_NAMES=$(echo "$STREAM_JSON" | grep -o '"name":"[^"]*","confName[^}]*"ready":true' | grep -o '"name":"[^"]*"' | sed 's/"name":"//g;s/"//g' | tr '\n' ' ' | sed 's/ $//')
                if [[ "$LIVE_COUNT" -gt 0 ]]; then
                    echo "  Streams  : $LIVE_COUNT live ($LIVE_NAMES)"
                else
                    echo "  Streams  : 0 live"
                fi
            fi
            MAVLINK_CONF="/opt/birddog/bdm/mavlink.conf"
            MAVPROXY_RUNNING=$(pgrep -f "mavproxy" >/dev/null 2>&1 && echo 1 || echo 0)
            WLAN0_ASSOC=$(iw dev wlan0 link 2>/dev/null | grep -c "Connected" || echo 0)
            if [[ -f "$MAVLINK_CONF" && "$MAVPROXY_RUNNING" -eq 1 && "$WLAN0_ASSOC" -gt 0 ]]; then
                source "$MAVLINK_CONF"
                echo "  MAVLink  : active ($ELRS_SSID)"
            else
                echo "  MAVLink  : inactive"
            fi
            echo "  Dashboard: http://${HOST}.local"
        elif [[ "$ROLE" == "BDC" ]]; then
            STREAM_SVC=$(systemctl is-active birddog-stream 2>/dev/null)
            echo "  Stream   : $STREAM_SVC"
            if [[ -f "$BIRDDOG_ROOT/bdc/bdc.conf" ]]; then
                source "$BIRDDOG_ROOT/bdc/bdc.conf"
                echo "  BDM      : $BDM_HOST"
                echo "  Cam      : $STREAM_NAME"
            fi
        fi
        echo "  Commit   : $COMMIT"
        echo "================================="
        echo ""
        ;;
    mavlink)
        HOST=$(hostname)
        ROLE="unknown"
        [[ "$HOST" =~ ^bdm-[0-9]{2}$ ]] && ROLE="BDM"
        if [[ "$ROLE" != "BDM" ]]; then
            echo "  birddog mavlink is only available on BDM nodes"
            exit 1
        fi
        MAVLINK_CONF="/opt/birddog/bdm/mavlink.conf"
        WLAN0_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP "(?<=inet )[^/]+" | head -1)
        WLAN0_ASSOC=$(iw dev wlan0 link 2>/dev/null | grep -c "Connected" || echo 0)
        MAVPROXY_RUNNING=$(pgrep -f "mavproxy" >/dev/null 2>&1 && echo 1 || echo 0)
        BRIDGE_ACTIVE=0
        [[ -f "$MAVLINK_CONF" && -n "$WLAN0_IP" && "$WLAN0_ASSOC" -gt 0 && "$MAVPROXY_RUNNING" -eq 1 ]] && BRIDGE_ACTIVE=1

        echo ""
        echo "================================="
        if [[ "$BRIDGE_ACTIVE" -eq 1 ]]; then
            source "$MAVLINK_CONF"
            echo "MAVLink Bridge — ACTIVE"
            echo "================================="
            echo "  SSID     : $ELRS_SSID"
            echo "  wlan0    : $WLAN0_IP (ELRS backpack)"
            echo "  wlan_ap  : 10.10.10.1 (BirdDog AP)"
            echo "  MAVProxy : running"
            echo "  Log      : /opt/birddog/logs/mavlink.log"
            echo "================================="
        else
            echo "MAVLink Bridge — INACTIVE"
            echo "================================="
        fi
        echo ""

        if [[ "$BRIDGE_ACTIVE" -eq 1 ]]; then
            echo "  [S]top   — stop bridge and restore wlan0"
            echo "  [X]      — exit"
            echo ""
            while true; do
                read -r -p "  Choice: " MAV_INPUT
                case "$MAV_INPUT" in
                    S)
                        echo ""
                        echo "  Stopping MAVLink bridge..."
                        sudo pkill -f "mavproxy" 2>/dev/null || true
                        sleep 1
                        WLAN0_RFKILL_IDX=$(cat /sys/class/net/wlan0/phy80211/rfkill*/index 2>/dev/null)
                        [[ -n "$WLAN0_RFKILL_IDX" ]] && echo 1 | tee "/sys/class/rfkill/rfkill${WLAN0_RFKILL_IDX}/soft" >/dev/null 2>&1 || true
                        sudo ip link set wlan0 down 2>/dev/null || true
                        sudo ip route del default dev wlan0 2>/dev/null || true
                        echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf >/dev/null
                        sudo rm -f "$MAVLINK_CONF" 2>/dev/null || true
                        echo "  Bridge stopped — wlan0 blocked — DNS restored"
                        echo ""
                        break
                        ;;
                    X) break ;;
                    *) echo "  Invalid — enter S or X" ;;
                esac
            done
        else
            echo "  [C]onfigure — start MAVLink bridge"
            echo "  [X]         — exit"
            echo ""
            while true; do
                read -r -p "  Choice: " MAV_INPUT
                case "$MAV_INPUT" in
                    C) exec sudo bash /usr/local/bin/birddog-mavlink-bridge.sh ;;
                    X) break ;;
                    *) echo "  Invalid — enter C or X" ;;
                esac
            done
        fi
        ;;
    web)
        HOST=$(hostname)
        API="http://localhost:9997/v3/paths/list"
        echo ""
        echo "================================="
        echo "BirdDog Streams"
        echo "================================="
        if ! curl -s --connect-timeout 3 "$API" >/dev/null 2>&1; then
            echo "  MediaMTX API not responding — is this a BDM node?"
            echo ""
            exit 1
        fi
        ITEMS=$(curl -s "$API" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('items', [])
if not items:
    print('  No streams found')
else:
    for item in items:
        name = item.get('name','?')
        ready = item.get('ready', False)
        if ready:
            print(f'  {name:<10} LIVE    rtsp://$HOST.local:8554/{name}')
" 2>/dev/null)
        if [[ -z "$ITEMS" ]]; then
            echo "  No active streams"
        else
            echo "$ITEMS"
        fi
        echo ""
        echo "  Dashboard : http://${HOST}.local"
        echo "================================="
        echo ""
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
        echo "  birddog status      quick node status summary"
        echo "  birddog mavlink     ELRS backpack MAVLink bridge (BDM only)"
        echo "  birddog web         show active camera streams"
        echo "  birddog radios      show radio interface layout"
        echo "  birddog version     show platform version"
        echo ""
        echo "  mesh help           mesh CLI reference"
        echo ""
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'birddog help' for usage"
        exit 1
        ;;
esac
BIRDDOG_EOF

chmod +x "$BIRDDOG_CLI"
echo "  BirdDog CLI installed → $BIRDDOG_CLI"

echo ""
echo "  Starting birddog_day hardware daemon..."

systemctl daemon-reload
systemctl enable birddog_day.service
systemctl restart birddog_day.service
# Allow birddog_day to complete boot_sequence (3s settle + beep) before reboot
sleep 6

if systemctl is-active --quiet birddog_day.service; then
    echo "  birddog_day  : running"
else
    echo "  WARNING: birddog_day service did not start — check: journalctl -u birddog_day"
fi

fi  # end full install only

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
echo "Install log: $LOG"
echo ""

if [[ "$GOLDEN_UPDATED" -eq 1 ]]; then
    echo "  NOTE: golden_image_creation.sh was updated on disk."
    echo "  This run executed the previous version already in memory."
    echo "  Changes will take effect on the next: birddog update"
    echo ""
fi

if [[ "$BIRDDOG_MODE" == "full" ]]; then
    echo "====================================="
    echo "Rebooting in 3 seconds..."
    echo "====================================="
    # Let the DHCP lease expire naturally — dhcpcd.conf is configured
    # to use MAC-based identity so the router will issue the same lease
    # on the next request without needing an explicit release.
    sleep 3
    reboot
else
    # Refresh mode — restart AP services to ensure clean state after
    # script updates. Harmless on BDC nodes where these services
    # are not running.
    systemctl restart hostapd 2>/dev/null || true
    systemctl restart dnsmasq 2>/dev/null || true
    echo "Next step: birddog configure"
fi
