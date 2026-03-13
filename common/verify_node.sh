#!/bin/bash
set -e

BIRDDOG_ROOT="/opt/birddog"

echo "================================="
echo "BirdDog Node Verification"
echo "================================="
date

HOST="$(hostname)"
ROLE="UNKNOWN"

[[ "$HOST" =~ ^bdm-[0-9]{2}$ ]] && ROLE="BDM"
[[ "$HOST" =~ ^bdc-[0-9]{2}$ ]] && ROLE="BDC"

NODE_NUM=$(echo "$HOST" | grep -oE '[0-9]{2}' || echo "00")
MESH_IP="10.10.20.$((10#$NODE_NUM * 10))"

echo ""
echo "  Node    : $HOST"
echo "  Role    : $ROLE"
echo "  Mesh IP : $MESH_IP"
echo ""

FAIL=0
WARN=0

pass() { echo "  ✔  $1"; }
warn() { echo "  ⚠  $1"; WARN=1; }
fail() { echo "  ✖  $1"; FAIL=1; }

# -------------------------------------------------------
# Identity
# -------------------------------------------------------

echo "---------------------------------"
echo "Identity"
echo "---------------------------------"

if [[ "$ROLE" == "UNKNOWN" ]]; then
    fail "Hostname not configured (currently: $HOST)"
    echo ""
    echo "  Run: birddog configure"
    echo ""
else
    pass "Hostname valid: $HOST"
fi

if [[ -f "$BIRDDOG_ROOT/version/COMMIT" ]]; then
    COMMIT=$(cat "$BIRDDOG_ROOT/version/COMMIT")
    pass "Platform commit: $COMMIT"
else
    warn "No version info — run birddog install"
fi

if getent hosts "${HOST}.local" >/dev/null 2>&1; then
    pass "mDNS resolving: ${HOST}.local"
else
    warn "mDNS not resolving — avahi may need a moment"
fi

# -------------------------------------------------------
# Radio layout
# udev assigns names by driver — wlan0 is onboard (blocked),
# wlan1 is mesh (Comfast), wlan2 is AP (Edimax, BDM only)
# -------------------------------------------------------

echo ""
echo "---------------------------------"
echo "Radio Layout"
echo "---------------------------------"

if ip link show wlan0 >/dev/null 2>&1; then
    STATE=$(ip link show wlan0 | awk '/state/{print $9}')
    pass "wlan0 present (onboard — expected $STATE/blocked)"
else
    warn "wlan0 not present (onboard BCM — check udev rules)"
fi

if ip link show wlan1 >/dev/null 2>&1; then
    MODE=$(iw dev wlan1 info 2>/dev/null | awk '/type/{print $2}')
    pass "wlan1 present — mesh adapter (mode: $MODE)"
else
    fail "wlan1 missing — Comfast adapter not detected"
fi

if [[ "$ROLE" == "BDM" ]]; then
    if ip link show wlan2 >/dev/null 2>&1; then
        MODE=$(iw dev wlan2 info 2>/dev/null | awk '/type/{print $2}')
        pass "wlan2 present — AP adapter (mode: $MODE)"
    else
        fail "wlan2 missing — Edimax adapter not detected"
    fi
fi

# -------------------------------------------------------
# Mesh
# -------------------------------------------------------

echo ""
echo "---------------------------------"
echo "Mesh"
echo "---------------------------------"

if systemctl is-active --quiet birddog-mesh.service; then
    pass "birddog-mesh running"
else
    warn "birddog-mesh not running"
fi

if iw dev wlan1 info 2>/dev/null | grep -q "mesh id birddog-mesh"; then
    pass "wlan1 joined mesh: birddog-mesh"
else
    warn "wlan1 not in mesh — may still be converging"
fi

if ip addr show wlan1 2>/dev/null | grep -q "$MESH_IP"; then
    pass "Mesh IP assigned: $MESH_IP"
else
    warn "Mesh IP $MESH_IP not on wlan1"
fi

# Check for at least one reachable mesh peer
PEER_FOUND=0
for slot in $(seq 1 5); do
    TARGET="10.10.20.$((slot * 10))"
    [[ "$TARGET" == "$MESH_IP" ]] && continue
    if ping -c1 -W1 "$TARGET" >/dev/null 2>&1; then
        pass "Mesh peer reachable: $TARGET"
        PEER_FOUND=1
        break
    fi
done
[[ "$PEER_FOUND" -eq 0 ]] && warn "No mesh peers reachable yet"

# -------------------------------------------------------
# Role-specific checks — BDM
# -------------------------------------------------------

if [[ "$ROLE" == "BDM" ]]; then

    echo ""
    echo "---------------------------------"
    echo "BDM — Access Point"
    echo "---------------------------------"

    systemctl is-active --quiet hostapd \
        && pass "hostapd running" \
        || fail "hostapd not running"

    systemctl is-active --quiet dnsmasq \
        && pass "dnsmasq running" \
        || fail "dnsmasq not running"

    ip addr show wlan2 2>/dev/null | grep -q "10.10.10.1" \
        && pass "AP IP configured: 10.10.10.1" \
        || fail "AP IP 10.10.10.1 missing on wlan2"

    ss -lntup 2>/dev/null | grep -q ":67 " \
        && pass "DHCP listening on port 67" \
        || fail "DHCP not listening"

    echo ""
    echo "---------------------------------"
    echo "BDM — MediaMTX"
    echo "---------------------------------"

    systemctl is-active --quiet mediamtx \
        && pass "mediamtx running" \
        || fail "mediamtx not running"

    ss -lnt 2>/dev/null | grep -q ":8554" \
        && pass "RTSP port 8554 open" \
        || fail "RTSP port 8554 closed"

    ss -lnt 2>/dev/null | grep -q ":8889" \
        && pass "WebRTC port 8889 open" \
        || warn "WebRTC port 8889 closed"

    ss -lnt 2>/dev/null | grep -q ":9997" \
        && pass "API port 9997 open" \
        || warn "API port 9997 closed"

    STREAM_COUNT=0
    if curl -s --connect-timeout 3 http://localhost:9997/v3/paths/list >/dev/null 2>&1; then
        pass "MediaMTX API responding"
        STREAM_COUNT=$(curl -s http://localhost:9997/v3/paths/list \
            | grep -c '"ready":true' 2>/dev/null || echo 0)
        echo "     Active streams: $STREAM_COUNT"
    else
        warn "MediaMTX API not responding"
    fi

    echo ""
    echo "---------------------------------"
    echo "BDM — Dashboard"
    echo "---------------------------------"

    systemctl is-active --quiet nginx \
        && pass "nginx running" \
        || fail "nginx not running"

    ss -lnt 2>/dev/null | grep -q ":80" \
        && pass "HTTP port 80 open" \
        || fail "HTTP port 80 closed"

    [[ -f "$BIRDDOG_ROOT/web/index.html" ]] \
        && pass "Dashboard present" \
        || fail "Dashboard missing — run birddog configure"

fi

# -------------------------------------------------------
# Role-specific checks — BDC
# -------------------------------------------------------

if [[ "$ROLE" == "BDC" ]]; then

    echo ""
    echo "---------------------------------"
    echo "BDC — Camera Stream"
    echo "---------------------------------"

    if [[ -f "$BIRDDOG_ROOT/bdc/bdc.conf" ]]; then
        source "$BIRDDOG_ROOT/bdc/bdc.conf"
        pass "BDC config present"
        echo "     BDM Host  : $BDM_HOST"
        echo "     Stream    : $STREAM_NAME"

        # Check BDM is reachable over mesh
        if ping -c1 -W2 "$BDM_HOST" >/dev/null 2>&1; then
            pass "BDM reachable: $BDM_HOST"
        else
            warn "BDM not reachable: $BDM_HOST — mesh may still be converging"
        fi
    else
        warn "BDC config missing — run birddog configure"
    fi

    systemctl is-active --quiet birddog-stream \
        && pass "birddog-stream running" \
        || warn "birddog-stream not running"

    pgrep -f rpicam-vid >/dev/null 2>&1 \
        && pass "rpicam-vid capturing" \
        || warn "rpicam-vid not active — check camera ribbon cable"

    pgrep -f ffmpeg >/dev/null 2>&1 \
        && pass "ffmpeg streaming" \
        || warn "ffmpeg not running — BDM may be unreachable"

fi

# -------------------------------------------------------
# Result
# -------------------------------------------------------

echo ""
echo "================================="

if [[ "$FAIL" -eq 1 ]]; then
    echo "NODE STATUS: FAILED"
    echo "================================="
    exit 1
elif [[ "$WARN" -eq 1 ]]; then
    echo "NODE STATUS: DEGRADED"
    echo "================================="
    exit 0
else
    echo "NODE STATUS: OPERATIONAL"
    echo "================================="
    exit 0
fi
