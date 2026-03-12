#!/bin/bash
set -e

echo "================================="
echo "BirdDog Node Verification"
echo "================================="
date

ROLE="UNKNOWN"
HOST="$(hostname)"

if [[ "$HOST" =~ ^bdm-[0-9]{2}$ ]]; then
    ROLE="BDM"
elif [[ "$HOST" =~ ^bdc-[0-9]{2}$ ]]; then
    ROLE="BDC"
fi

echo ""
echo "Node        : $HOST"
echo "Detected Role : $ROLE"
echo ""

FAIL=0
WARN=0

pass() { echo "✔ $1"; }
warn() { echo "⚠ $1"; WARN=1; }
fail() { echo "✖ $1"; FAIL=1; }

echo "---------------------------------"
echo "Identity"
echo "---------------------------------"

if [[ "$ROLE" == "UNKNOWN" ]]; then
    fail "Hostname format invalid"
else
    pass "Hostname format valid"
fi

if getent hosts "$HOST.local" >/dev/null 2>&1; then
    pass "mDNS resolving"
else
    warn "mDNS not resolving"
fi

echo ""
echo "---------------------------------"
echo "Radio Layout"
echo "---------------------------------"

for IF in wlan0 wlan1 wlan2
do
    if ip link show $IF >/dev/null 2>&1; then
        TYPE=$(iw dev $IF info 2>/dev/null | awk '/type/ {print $2}')
        pass "$IF present ($TYPE)"
    else
        fail "$IF missing"
    fi
done

echo ""
echo "---------------------------------"
echo "Mesh Readiness"
echo "---------------------------------"

if systemctl is-enabled birddog-mesh.service >/dev/null 2>&1; then
    pass "Mesh service enabled"
else
    warn "Mesh service not enabled"
fi

if systemctl is-active birddog-mesh.service >/dev/null 2>&1; then
    pass "Mesh service running"
else
    warn "Mesh service not running"
fi

echo ""
echo "---------------------------------"
echo "Role Specific Checks"
echo "---------------------------------"

# ==========================================================
# ======================= BDM ==============================
# ==========================================================

if [[ "$ROLE" == "BDM" ]]; then

    echo ""
    echo "Access Point"

    if systemctl is-active hostapd >/dev/null 2>&1; then
        pass "hostapd running"
    else
        fail "hostapd not running"
    fi

    if systemctl is-active dnsmasq >/dev/null 2>&1; then
        pass "dnsmasq running"
    else
        fail "dnsmasq not running"
    fi

    if ip addr show wlan2 | grep -q "10.10.10.1"; then
        pass "AP IP configured"
    else
        fail "AP IP missing"
    fi

    if ss -lntup | grep -q ":67 "; then
        pass "DHCP port listening"
    else
        fail "DHCP not listening"
    fi

    echo ""
    echo "MediaMTX"

    if systemctl is-active mediamtx >/dev/null 2>&1; then
        pass "mediamtx running"
    else
        fail "mediamtx not running"
    fi

    if ss -lnt | grep -q ":8554"; then
        pass "RTSP port open"
    else
        fail "RTSP port closed"
    fi

    if ss -lnt | grep -q ":8889"; then
        pass "WebRTC port open"
    else
        warn "WebRTC port closed"
    fi

    if ss -lnt | grep -q ":9997"; then
        pass "API port open"
    else
        warn "API port closed"
    fi

    if curl -s http://localhost:9997/v3/paths/list >/dev/null 2>&1; then
        pass "API responding"
    else
        warn "API not responding"
    fi

    echo ""
    echo "Dashboard"

    if systemctl is-active nginx >/dev/null 2>&1; then
        pass "nginx running"
    else
        fail "nginx not running"
    fi

    if ss -lnt | grep -q ":80"; then
        pass "HTTP port open"
    else
        fail "HTTP port closed"
    fi

    if [ -f /opt/birddog/web/index.html ]; then
        pass "dashboard present"
    else
        fail "dashboard missing"
    fi

fi

# ==========================================================
# ======================= BDC ==============================
# ==========================================================

if [[ "$ROLE" == "BDC" ]]; then

    echo ""
    echo "Camera Stream"

    if systemctl is-active birddog-stream >/dev/null 2>&1; then
        pass "stream service running"
    else
        warn "stream service not running"
    fi

    if pgrep -f rpicam-vid >/dev/null 2>&1; then
        pass "camera capture active"
    else
        warn "camera not capturing"
    fi

fi

echo ""
echo "================================="

if [[ "$FAIL" == "1" ]]; then
    echo "NODE STATUS: FAILED"
    exit 1
elif [[ "$WARN" == "1" ]]; then
    echo "NODE STATUS: DEGRADED"
    exit 0
else
    echo "NODE STATUS: OPERATIONAL"
    exit 0
fi

echo "================================="
