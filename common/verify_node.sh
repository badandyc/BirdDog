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

echo ""
echo "  Node : $HOST"
echo "  Role : $ROLE"
echo ""

NODE_NUM=$(echo "$HOST" | grep -oE '[0-9]{2}' || echo "00")
if [[ "$ROLE" == "BDM" ]]; then
    MESH_IP="10.10.20.$((10#$NODE_NUM))"
else
    MESH_IP="10.10.20.$((10#$NODE_NUM * 10))"
fi

if [[ "$ROLE" != "UNKNOWN" ]]; then
    echo "  Mesh IP : $MESH_IP  (on bat0)"
fi
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
    if [[ "$HOST" == "birddog" ]]; then
        warn "Node not configured — golden image baseline (run: birddog configure)"
    else
        warn "Node not configured — hostname '$HOST' not a valid role (run: birddog configure)"
    fi
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
# -------------------------------------------------------

echo ""
echo "---------------------------------"
echo "Radio Layout"
echo "---------------------------------"

if ip link show wlan0 >/dev/null 2>&1; then
    STATE=$(ip link show wlan0 | awk '/state/{print $9}')
    pass "wlan0 present (onboard brcmfmac — $STATE, blocked)"
else
    warn "wlan0 not present — check udev rules"
fi

if ip link show wlan_mesh_5 >/dev/null 2>&1; then
    MODE=$(iw dev wlan_mesh_5 info 2>/dev/null | awk '/type/{print $2}')
    pass "wlan_mesh_5 present — MT7612U mesh adapter (mode: $MODE)"
else
    fail "wlan_mesh_5 missing — Comfast adapter not detected"
fi

if [[ "$ROLE" == "BDM" ]]; then
    if ip link show wlan_ap >/dev/null 2>&1; then
        MODE=$(iw dev wlan_ap info 2>/dev/null | awk '/type/{print $2}')
        pass "wlan_ap present — Edimax AP adapter (mode: $MODE)"
    else
        fail "wlan_ap missing — Edimax adapter not detected"
    fi
fi

# -------------------------------------------------------
# Mesh (batman-adv)
# -------------------------------------------------------

echo ""
echo "---------------------------------"
echo "Mesh (batman-adv)"
echo "---------------------------------"

if systemctl is-active --quiet birddog-mesh.service; then
    pass "birddog-mesh service running"
else
    warn "birddog-mesh service not running"
fi

# bat0 is the batman-adv virtual L3 interface — its presence and wlan_mesh_5
# attachment confirm batman-adv is active
if ip link show bat0 >/dev/null 2>&1; then
    if batctl if 2>/dev/null | grep -q "wlan_mesh_5"; then
        pass "bat0 up — wlan_mesh_5 attached to batman-adv"
    else
        warn "bat0 exists but wlan_mesh_5 not attached — batman-adv not fully up"
    fi
else
    warn "bat0 not present — batman-adv not active (may still be converging)"
fi

MESH_IF_TYPE=$(iw dev wlan_mesh_5 info 2>/dev/null | awk '/type/{print $2}')
if [[ "$MESH_IF_TYPE" == "mesh" ]]; then
    pass "wlan_mesh_5 in 802.11s mesh point mode"
else
    warn "wlan_mesh_5 not in mesh point mode (type: ${MESH_IF_TYPE:-unknown}) — may still be converging"
fi

if [[ "$ROLE" != "UNKNOWN" ]]; then
    if ip addr show bat0 2>/dev/null | grep -q "$MESH_IP"; then
        pass "Mesh IP assigned on bat0: $MESH_IP"
    else
        warn "Mesh IP $MESH_IP not on bat0 — may still be converging"
    fi
fi

if [[ "$ROLE" != "UNKNOWN" ]]; then
    PEER_FOUND=0
    # Check batman-adv neighbor table first
    NEIGH=$(batctl neighbors 2>/dev/null | awk 'NR>2 && /[0-9a-f:]/{print $1}' | head -1)
    if [[ -n "$NEIGH" ]]; then
        pass "batman-adv direct neighbor present: $NEIGH"
        PEER_FOUND=1
    else
        # Fall back to pinging known mesh IPs via bat0
        for TARGET in 10.10.20.1 10.10.20.2 10.10.20.3 10.10.20.4 10.10.20.5 \
                      10.10.20.10 10.10.20.20 10.10.20.30 10.10.20.40 10.10.20.50; do
            [[ "$TARGET" == "$MESH_IP" ]] && continue
            if ping -c1 -W1 -I bat0 "$TARGET" >/dev/null 2>&1; then
                pass "Mesh peer reachable via bat0: $TARGET"
                PEER_FOUND=1
                break
            fi
        done
    fi
    [[ "$PEER_FOUND" -eq 0 ]] && warn "No mesh peers reachable yet"
fi

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

    ip addr show wlan_ap 2>/dev/null | grep -q "10.10.10.1" \
        && pass "AP IP configured: 10.10.10.1 on wlan_ap" \
        || fail "AP IP 10.10.10.1 missing on wlan_ap"

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

    if curl -s --connect-timeout 3 http://localhost:9997/v3/paths/list >/dev/null 2>&1; then
        pass "MediaMTX API responding"
        STREAM_COUNT=$(curl -s http://localhost:9997/v3/paths/list \
            | grep -c '"ready":true' 2>/dev/null) || STREAM_COUNT=0
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

        if ping -c1 -W2 -I bat0 "$BDM_HOST" >/dev/null 2>&1; then
            pass "BDM reachable: $BDM_HOST (mesh via bat0)"
        elif ping -c1 -W2 "$BDM_HOST" >/dev/null 2>&1; then
            pass "BDM reachable: $BDM_HOST (eth0 — mesh not yet available)"
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

    if pgrep -f ffmpeg >/dev/null 2>&1; then
        if ping -c1 -W1 -I bat0 "$BDM_HOST" >/dev/null 2>&1; then
            pass "ffmpeg streaming (mesh via bat0)"
        else
            pass "ffmpeg streaming (eth0 — mesh not yet available)"
        fi
    else
        warn "ffmpeg not running — BDM may be unreachable"
    fi

fi

# -------------------------------------------------------
# Result
# -------------------------------------------------------

echo ""
echo "================================="

if [[ "$FAIL" -eq 1 ]]; then
    STATUS="FAILED"
elif [[ "$ROLE" == "UNKNOWN" ]]; then
    STATUS="NOT CONFIGURED"
elif [[ "$WARN" -eq 1 ]]; then
    STATUS="DEGRADED"
else
    STATUS="OPERATIONAL"
fi

echo "NODE STATUS: $STATUS"
echo "================================="
echo ""

if [[ "$ROLE" == "UNKNOWN" ]]; then
    echo "  Run: birddog configure"
    echo ""
else
    echo "  LED reference:"
    echo "    White  — power     (on=bus powered)"
    echo "    Yellow — bootstrap (solid=unconfigured or switch/role mismatch + SOS every 30s)"
    echo "    Blue   — mesh      (off=down  slow-blink=joining  fast-blink=no peer  solid=joined)"
    if [[ "$ROLE" == "BDM" ]]; then
        echo "    Green  — mediamtx  (off=down  fast-blink=up/no streams  solid=streams active)"
    else
        echo "    Green  — stream    (off=failed  slow-blink=restarting  solid=streaming)"
    fi
    echo "    Red    — camera    (on=fault)"
    echo ""
fi

[[ "$FAIL" -eq 1 ]] && exit 1 || exit 0
