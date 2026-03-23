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
# PERMS
# --------------------------------------------------

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
import random

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
BLINK_SLOW       = 0.5    # 1Hz  — joining mesh (service up, not in mesh mode)
BLINK_FAST       = 0.125  # 4Hz  — in mesh, no peer yet
PRESS_SHORT      = 1.0    # 1s release — TBD
PRESS_ROLL_CALL  = 5.0    # 5s hold — LED roll call
LONG_PRESS_TIME  = 10.0   # 10s hold — shutdown

# ── state ──
# led_blue_blink: 0=off  1=slow(joining)  2=fast(no peer)  3=solid
led_blue_blink       = 0
led_green_blink      = False
last_state_check     = 0
last_blink_slow      = 0
last_blink_fast      = 0
blink_phase_slow     = False
blink_phase_fast     = False
button_press_time    = None
roll_call_fired      = False  # track if roll call already fired during this hold

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
    # pattern: list of (on_time, off_time) tuples in seconds
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

def status_beep():
    beep([(0.1, 0.15), (0.1, 0.15), (0.1, 0)])

def role_beep_bdc():
    # 1 long tone — BDC confirmed
    beep([(0.8, 0)])

def role_beep_bdm():
    # 2 long tones — BDM confirmed
    beep([(0.8, 0.3), (0.8, 0)])

def sos_beep():
    # SOS x2 — switch/config mismatch
    dot = 0.1
    dash = 0.3
    gap = 0.1
    letter_gap = 0.3
    word_gap = 0.6
    sos = [
        (dot, gap), (dot, gap), (dot, letter_gap),   # S
        (dash, gap), (dash, gap), (dash, letter_gap), # O
        (dot, gap), (dot, gap), (dot, word_gap),      # S
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
    # Save current LED states
    saved = {}
    for pin in [PIN_LED_BLUE, PIN_LED_GREEN, PIN_LED_YELLOW, PIN_LED_RED]:
        saved[pin] = GPIO.input(pin)

    # All off
    all_leds_off()
    time.sleep(0.1)

    # Flash each LED in sequence
    led_flash(PIN_LED_BLUE)
    time.sleep(0.1)
    led_flash(PIN_LED_GREEN)
    time.sleep(0.1)
    led_flash(PIN_LED_YELLOW)
    time.sleep(0.1)
    led_flash(PIN_LED_RED)
    time.sleep(0.1)

    # 3 quick buzzes
    status_beep()

    # Restore LED states
    for pin, state in saved.items():
        GPIO.output(pin, state)

def read_role():
    # open (high) = BDM, closed (low) = BDC
    return "bdm" if GPIO.input(PIN_SWITCH) == GPIO.HIGH else "bdc"

def committed_role():
    # Read committed role from hostname
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
    # Node is in bootstrap state if hostname is unconfigured
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

def check_state():
    global led_blue_blink, led_green_blink

    # ── yellow: bootstrap / mismatch ──
    bootstrap = is_bootstrap()
    role_sw   = read_role()
    role_cfg  = committed_role()
    mismatch  = (not bootstrap) and (role_cfg is not None) and (role_sw != role_cfg)

    if bootstrap or mismatch:
        GPIO.output(PIN_LED_YELLOW, GPIO.HIGH)
    else:
        GPIO.output(PIN_LED_YELLOW, GPIO.LOW)

    # ── blue: mesh ──
    mesh_svc  = service_active("birddog-mesh")
    wlan1_up  = os.path.exists("/sys/class/net/wlan1")
    joined    = mesh_joined()
    has_peer  = mesh_has_peer()

    if not mesh_svc or not wlan1_up:
        # service down or adapter missing -- off
        led_blue_blink = 0
        GPIO.output(PIN_LED_BLUE, GPIO.LOW)
    elif not joined:
        # service up, adapter present, not in mesh mode -- slow blink (joining)
        led_blue_blink = 1
    elif not has_peer:
        # in mesh mode but no peer -- fast blink (searching)
        led_blue_blink = 2
    else:
        # mesh joined with peer -- solid
        led_blue_blink = 3
        GPIO.output(PIN_LED_BLUE, GPIO.HIGH)

    # ── green: stream ──
    stream_active     = service_active("birddog-stream")
    stream_activating = service_activating("birddog-stream")

    if stream_activating:
        led_green_blink = True
    elif stream_active:
        led_green_blink = False
        GPIO.output(PIN_LED_GREEN, GPIO.HIGH)
    else:
        led_green_blink = False
        GPIO.output(PIN_LED_GREEN, GPIO.LOW)

    # ── red: camera ──
    GPIO.output(PIN_LED_RED, GPIO.LOW if camera_ok() else GPIO.HIGH)

def update_blink(now):
    global last_blink_slow, last_blink_fast, blink_phase_slow, blink_phase_fast

    # slow blink (1Hz)
    if now - last_blink_slow >= BLINK_SLOW:
        blink_phase_slow = not blink_phase_slow
        last_blink_slow = now
        if led_blue_blink == 1:
            GPIO.output(PIN_LED_BLUE, GPIO.HIGH if blink_phase_slow else GPIO.LOW)
        if led_green_blink:
            GPIO.output(PIN_LED_GREEN, GPIO.HIGH if blink_phase_slow else GPIO.LOW)

    # fast blink (4Hz)
    if now - last_blink_fast >= BLINK_FAST:
        blink_phase_fast = not blink_phase_fast
        last_blink_fast = now
        if led_blue_blink == 2:
            GPIO.output(PIN_LED_BLUE, GPIO.HIGH if blink_phase_fast else GPIO.LOW)

def check_button(now):
    global button_press_time, roll_call_fired
    pressed = GPIO.input(PIN_BUTTON) == GPIO.LOW

    if pressed and button_press_time is None:
        button_press_time = now
        roll_call_fired = False

    elif pressed and button_press_time is not None:
        held = now - button_press_time

        # 5s hold — fire roll call once
        if held >= PRESS_ROLL_CALL and not roll_call_fired:
            status_roll_call()
            roll_call_fired = True

        # 10s hold — shutdown
        if held >= LONG_PRESS_TIME:
            all_leds_off()
            GPIO.output(PIN_LED_RED, GPIO.HIGH)
            shutdown_beep()
            GPIO.cleanup()
            os.system("sudo poweroff")

    elif not pressed and button_press_time is not None:
        held = now - button_press_time
        if held >= 0.05 and held < PRESS_ROLL_CALL:
            # short press under 5s — TBD
            pass
        button_press_time = None
        roll_call_fired = False

def boot_sequence():
    role_sw  = read_role()
    bootstrap = is_bootstrap()
    role_cfg  = committed_role()
    mismatch  = (not bootstrap) and (role_cfg is not None) and (role_sw != role_cfg)

    if mismatch:
        # switch/config mismatch — yellow on, SOS x2, safe state
        GPIO.output(PIN_LED_YELLOW, GPIO.HIGH)
        sos_beep()
    elif bootstrap:
        # never configured — yellow on, boot beep
        GPIO.output(PIN_LED_YELLOW, GPIO.HIGH)
        boot_beep()
    else:
        # configured and switch matches — role confirmation beep
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
# Falls back to random bootstrap IP (10.10.20.240-254) if unconfigured.
# Runs as birddog-mesh.service (systemd).

LOG="/opt/birddog/mesh/mesh_runtime.log"
MESH_CONF="/opt/birddog/mesh/mesh.conf"

# ── Determine mesh IP ──
if [[ -f "$MESH_CONF" ]]; then
    source "$MESH_CONF"
else
    # Bootstrap — no identity yet, pick random temp IP
    OCTET=$(( RANDOM % 15 + 240 ))
    MESH_IP="10.10.20.${OCTET}/24"
fi

MESH_IP="${MESH_IP:-10.10.20.254/24}"

# State machine states:
#   WAIT_INTERFACE  wlan1 not yet visible
#   NORMALIZE       first join attempt in progress
#   CONVERGING      joined, waiting for first peer
#   STEADY          peer seen recently
#   SUSPECT         no peer for SUSPECT_THRESHOLD seconds
#   RECOVERY        no peer for RECOVERY_THRESHOLD seconds — rejoin

STATE="INIT"
LAST_PEER_TIME=0
LAST_JOIN_TIME=0

JOIN_COOLDOWN=15
SUSPECT_THRESHOLD=15
RECOVERY_THRESHOLD=40

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

    # Set RSSI threshold — reject direct peers weaker than -65 dBm
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

# ── Main loop ──

log "================================="
log "Mesh runtime start"
log "Hostname : $(hostname)"
log "Mesh IP  : $MESH_IP"

# Disable dhcpcd — we manage wlan1 addressing manually
systemctl stop dhcpcd.service 2>/dev/null || true
systemctl disable dhcpcd.service 2>/dev/null || true

sleep 5

STATE="WAIT_INTERFACE"
log_state "$STATE"

while true; do

    # ---------- WAIT_INTERFACE ----------
    if ! interface_exists; then
        if [[ "$STATE" != "WAIT_INTERFACE" ]]; then
            STATE="WAIT_INTERFACE"
            log_state "$STATE"
        fi
        sleep 2
        continue
    fi

    # ---------- FIRST JOIN ----------
    if [[ "$STATE" == "WAIT_INTERFACE" ]]; then
        STATE="NORMALIZE"
        log_state "$STATE"
        normalize_and_join || true
        STATE="CONVERGING"
        log_state "$STATE"
    fi

    # ---------- HARD CORRECTNESS CHECK ----------
    if ! mesh_joined; then
        log "mesh membership lost"
        STATE="RECOVERY"
        log_state "$STATE"
    fi

    assign_ip_if_missing

    # ---------- PEER DETECTION ----------
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

    # ---------- STATE MACHINE ----------
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

    # ---------- SLEEP BY STATE ----------
    case "$STATE" in
        CONVERGING) sleep 2  ;;
        SUSPECT)    sleep 5  ;;
        STEADY)
            while IFS= read -r line; do
                PEER_IP=$(echo "$line" | awk '{print $1}')
                [[ -n "$PEER_IP" ]] && ping -c1 -W1 "$PEER_IP" >/dev/null 2>&1 || true
            done < <(ip neigh show dev wlan1 2>/dev/null | grep -v FAILED)
            sleep $(( 30 + RANDOM % 5 ))
            ;;
        *)          sleep 5  ;;
    esac

done
MESH_RUNTIME

chmod +x /usr/local/bin/birddog-mesh-join.sh
echo "  birddog-mesh-join.sh installed → /usr/local/bin/birddog-mesh-join.sh"

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
# Written as a plain file to avoid quoting issues inside heredocs

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
