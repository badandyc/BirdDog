#!/bin/bash
set -e
set -o pipefail

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

for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool curl tar iw wireless-tools python3-rpi.gpio; do
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

    for pkg in ffmpeg rpicam-apps avahi-daemon avahi-utils nginx hostapd dnsmasq git ethtool curl tar iw wireless-tools python3-rpi.gpio; do
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
# Block onboard wifi by driver name — index-based blocking is unreliable
# across reboots and hardware configurations.
# brcmfmac is the onboard Pi WiFi driver.
ExecStart=/bin/bash -c '    for phy in /sys/class/ieee80211/*/; do         driver=$(basename $(readlink $phy/device/driver 2>/dev/null) 2>/dev/null);         name=$(cat $phy/name 2>/dev/null);         if [[ "$driver" == "brcmfmac" ]]; then             rfkill block "$name" 2>/dev/null || true;         fi;     done'
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
echo "commit-$REMOTE_COMMIT" > "$VERSION_FILE"
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

def role_beep_bdc():
    beep([(0.8, 0)])

def role_beep_bdm():
    beep([(0.8, 0.3), (0.8, 0)])

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

def mesh_joined():
    try:
        result = subprocess.run(
            ["iw", "dev", "wlan1", "info"],
            capture_output=True, text=True, timeout=3
        )
        return "type mesh point" in result.stdout
    except Exception:
        return False

def mesh_has_peer():
    try:
        result = subprocess.run(
            ["iw", "dev", "wlan1", "station", "dump"],
            capture_output=True, text=True, timeout=3
        )
        return "Station" in result.stdout
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

    # ── blue: mesh ──
    mesh_svc  = service_active("birddog-mesh")
    wlan1_up  = os.path.exists("/sys/class/net/wlan1")
    joined    = mesh_joined()
    has_peer  = mesh_has_peer()

    if not mesh_svc or not wlan1_up:
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
            # mediamtx not running — off
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
    GPIO.output(PIN_LED_RED, GPIO.LOW if camera_ok() else GPIO.HIGH)

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
        if role_sw == "bdc":
            role_beep_bdc()
        else:
            role_beep_bdm()

def main():
    global last_state_check
    setup()
    boot_sequence()
    check_state()
    last_state_check = time.time()

    while True:
        now = time.time()
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

LOG_DIR="/opt/birddog/mesh"
mkdir -p "$LOG_DIR"

cat > /usr/local/bin/birddog-mesh-join.sh <<'MESH_RUNTIME'
#!/bin/bash

# BirdDog Mesh Runtime
# Manages 802.11s mesh membership on wlan1.
# Reads mesh IP from /opt/birddog/mesh/mesh.conf at startup.
# Falls back to random bootstrap IP (10.10.20.231-254) if unconfigured.
# Runs as birddog-mesh.service (systemd).

LOG="/opt/birddog/mesh/mesh_runtime.log"
MESH_CONF="/opt/birddog/mesh/mesh.conf"

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
    ip link show wlan1 >/dev/null 2>&1
}

mesh_joined() {
    iw dev wlan1 info 2>/dev/null | grep -q "type mesh point"
}

assign_ip_if_missing() {
    if ! ip addr show wlan1 2>/dev/null | grep -q "$MESH_IP"; then
        ip addr replace "$MESH_IP" dev wlan1 >> "$LOG" 2>&1 || true
        log "mesh IP restored: $MESH_IP"
    fi
}

normalize_and_join() {
    local NOW
    NOW=$(date +%s)

    if (( NOW - LAST_JOIN_TIME < JOIN_COOLDOWN )); then
        log "join cooldown active — skipping"
        return
    fi

    log "normalize + join attempt"

    ip link set wlan1 down >> "$LOG" 2>&1 || true
    sleep 1

    iw dev wlan1 set type mp >> "$LOG" 2>&1 || {
        log "ERROR: could not set wlan1 to mesh point mode"
        return 1
    }

    iw dev wlan1 set power_save off >> "$LOG" 2>&1 || true
    ip link set wlan1 up >> "$LOG" 2>&1 || true
    sleep 1

    iw dev wlan1 set channel 1 HT20 >> "$LOG" 2>&1 || true

    iw dev wlan1 mesh join birddog-mesh freq 2412 HT20 >> "$LOG" 2>&1 || {
        log "mesh join failed — will retry"
        sleep $(( RANDOM % 4 + 2 ))
        LAST_JOIN_TIME=$(date +%s)
        return 1
    }

    ip addr replace "$MESH_IP" dev wlan1 >> "$LOG" 2>&1 || true
    iw dev wlan1 set mesh_param mesh_rssi_threshold -65 >> "$LOG" 2>&1 || true

    LAST_JOIN_TIME=$(date +%s)
    log "join successful — IP: $MESH_IP"
}

check_for_peer() {
    local PEER_FOUND=0

    if ip neigh show dev wlan1 2>/dev/null | grep -qv "FAILED"; then
        PEER_FOUND=1
    else
        local OWN_OCTET
        OWN_OCTET=$(echo "$MESH_IP" | cut -d/ -f1 | awk -F. '{print $4}')
        local OWN_NUM=$(( OWN_OCTET / 10 ))

        for delta in -1 1 -2 2 -3 3; do
            local SLOT=$(( OWN_NUM + delta ))
            [[ "$SLOT" -lt 1 || "$SLOT" -gt 25 ]] && continue
            local TARGET="10.10.20.$((SLOT * 10))"
            ping -c1 -W1 "$TARGET" >/dev/null 2>&1 || true
            if ip neigh show dev wlan1 2>/dev/null | grep -q "$TARGET"; then
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

systemctl stop dhcpcd.service 2>/dev/null || true
systemctl disable dhcpcd.service 2>/dev/null || true

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

    if ! mesh_joined; then
        log "mesh membership lost"
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
            normalize_and_join || true
            STATE="CONVERGING"
            log_state "$STATE"
            ;;

    esac

    case "$STATE" in
        CONVERGING) sleep 2  ;;
        SUSPECT)    sleep 5  ;;
        STEADY)
            while IFS= read -r line; do
                PEER_IP=$(echo "$line" | awk '{print $1}')
                [[ -n "$PEER_IP" ]] && ping -c1 -W1 "$PEER_IP" >/dev/null 2>&1 || true
            done < <(ip neigh show dev wlan1 2>/dev/null | grep -v FAILED)
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
# Connects wlan0 to ELRS TX backpack AP and forwards
# MAVLink UDP ports to the BirdDog AP (wlan2).
# Not persistent — reboot resets wlan0 to blocked state.

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
echo "  on the AP network receives drone telemetry on UDP 14550."
echo ""
echo "  [UID]  — enter 6-digit code from backpack"
echo "  [SSID] — enter full network name manually"
echo "  [X]    — cancel"
echo ""

while true; do
    read -r -p "  Choice: " MODE_INPUT
    [[ "$MODE_INPUT" == "UID" || "$MODE_INPUT" == "SSID" || "$MODE_INPUT" == "X" ]] && break
    echo "  Invalid — enter UID, SSID, or X"
done

if [[ "$MODE_INPUT" == "X" ]]; then
    echo "  Cancelled."
    exit 0
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

# Unblock wlan0
rfkill unblock wifi 2>/dev/null || true
sleep 1

# Write wpa_supplicant config
WPA_CONF="/tmp/birddog_elrs_wpa.conf"
cat > "$WPA_CONF" << EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=0

network={
    ssid="${ELRS_SSID}"
    psk="${ELRS_PASSWORD}"
    key_mgmt=WPA-PSK
}
EOF

ip link set wlan0 up 2>/dev/null || true
sleep 1

echo "  Connecting to $ELRS_SSID ..."
wpa_supplicant -B -i wlan0 -c "$WPA_CONF" -P /tmp/birddog_elrs_wpa.pid 2>/dev/null || true

# DHCP with 8 second timeout — fail fast
dhclient -1 -timeout 8 -pf /tmp/birddog_elrs_dhcp.pid wlan0 2>/dev/null || true

WLAN0_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet )[^/]+' | head -1)

if [[ -z "$WLAN0_IP" ]]; then
    echo ""
    echo "  Could not connect to $ELRS_SSID"
    echo "  Check UID/SSID and try again — reboot to reset wlan0"
    exit 1
fi

echo "  Connected — wlan0 IP: $WLAN0_IP"

# Remove default route via wlan0 — forward only, never use as internet gateway
ip route del default dev wlan0 2>/dev/null || true

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

# Forward MAVLink UDP ports between wlan0 and wlan2
iptables -A FORWARD -i wlan0 -o wlan2 -p udp --dport 14550 -j ACCEPT
iptables -A FORWARD -i wlan2 -o wlan0 -p udp --dport 14555 -j ACCEPT
iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
iptables -t nat -A POSTROUTING -o wlan2 -j MASQUERADE

# Save state for status check
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
echo "  wlan0  : $WLAN0_IP (ELRS backpack)"
echo "  wlan2  : 10.10.10.1 (BirdDog AP)"
echo "  Ports  : UDP 14550 (telemetry) / 14555 (commands)"
echo "  Connect Mission Planner to BirdDog AP → UDP 14550"
echo "================================="
echo ""
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
        for IFACE in wlan0 wlan1 wlan2; do
            if ip link show "$IFACE" >/dev/null 2>&1; then
                DRV=$(readlink /sys/class/net/$IFACE/device/driver 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
                MODE=$(iw dev "$IFACE" info 2>/dev/null | awk '/type/ {print $2}' || echo "unknown")
                STATE=$(ip link show "$IFACE" | grep -oP '(?<=state )\w+' || echo "unknown")
                printf "  %-6s driver=%-12s mode=%-10s state=%s\n" "$IFACE" "$DRV" "$MODE" "$STATE"
            fi
        done
        ;;
    version)
        COMMIT=$(cat "$BIRDDOG_ROOT/version/COMMIT" 2>/dev/null || echo "unknown")
        BUILD=$(cat "$BIRDDOG_ROOT/version/BUILD" 2>/dev/null || echo "unknown")
        echo "BirdDog"
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
        PEERS=$(iw dev wlan1 station dump 2>/dev/null | grep -c "^Station" || echo 0)
        MESH_IP=$(ip -4 addr show wlan1 2>/dev/null | grep -oP "(?<=inet )[^/]+" | head -1)
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
        if [[ -f "$MAVLINK_CONF" ]]; then
            source "$MAVLINK_CONF"
            WLAN0_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP "(?<=inet )[^/]+" | head -1)
            if [[ -n "$WLAN0_IP" && "$MAVLINK_ACTIVE" == "1" ]]; then
                echo ""
                echo "================================="
                echo "MAVLink Bridge — ACTIVE"
                echo "================================="
                echo "  SSID   : $ELRS_SSID"
                echo "  wlan0  : $WLAN0_IP (ELRS backpack)"
                echo "  wlan2  : 10.10.10.1 (BirdDog AP)"
                echo "  Ports  : UDP 14550 (telemetry) / 14555 (commands)"
                echo "================================="
                echo ""
                exit 0
            fi
        fi
        exec sudo bash /usr/local/bin/birddog-mavlink-bridge.sh
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
