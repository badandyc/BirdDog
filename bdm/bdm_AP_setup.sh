#!/bin/bash
set -e
set -o pipefail

mkdir -p /opt/birddog/logs

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG="/opt/birddog/logs/install_ap_${TIMESTAMP}.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog AP Setup"
echo "================================="
date

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo bash /opt/birddog/bdm/bdm_AP_setup.sh"
    exit 1
fi

AP_IF="wlan2"
AP_IP="10.10.10.1/24"
SSID="BirdDog"
PASSPHRASE="StrongPass123"

ELRS_PASSWORD="expresslrs"
ELRS_SSID_BASE="ExpressLRS TX Backpack"
MAVLINK_CONF="/opt/birddog/bdm/mavlink.conf"

# -------------------------------------------------------
# Phase 1 — Write all network config files FIRST
# -------------------------------------------------------

echo ""
echo "=== Writing network configuration ==="

mkdir -p /etc/systemd/network

ETH0_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet )[^/]+' | head -1)
ETH0_GW=$(ip route show default dev eth0 2>/dev/null | grep -oP '(?<=via )[^ ]+' | head -1)
ETH0_PREFIX=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet )[0-9.]+/\K[0-9]+' | head -1)
ETH0_PREFIX=${ETH0_PREFIX:-24}

if [[ -n "$ETH0_IP" && -n "$ETH0_GW" ]]; then
    echo "  eth0 current IP : $ETH0_IP/$ETH0_PREFIX  gw $ETH0_GW"
    echo "  Holding IP through transition..."

    cat > /etc/systemd/network/10-eth0.network << EOF
[Match]
Name=eth0

[Network]
Address=${ETH0_IP}/${ETH0_PREFIX}
Gateway=${ETH0_GW}
DNS=8.8.8.8
ConfigureWithoutCarrier=yes

[DHCP]
ClientIdentifier=mac
SendHostname=yes
EOF

else
    echo "  WARNING: could not detect eth0 IP — falling back to DHCP only"
    cat > /etc/systemd/network/10-eth0.network << EOF
[Match]
Name=eth0

[Network]
DHCP=yes

[DHCP]
ClientIdentifier=mac
SendHostname=yes
EOF
fi

cat > /etc/systemd/network/20-wlan1.network << EOF
[Match]
Name=wlan1

[Network]
DHCP=no
LinkLocalAddressing=no
EOF

cat > /etc/systemd/network/30-wlan2.network << EOF
[Match]
Name=${AP_IF}

[Network]
Address=${AP_IP}
ConfigureWithoutCarrier=yes
LinkLocalAddressing=no
EOF

echo "  Network config files written"

# -------------------------------------------------------
# Phase 2 — Regulatory + rfkill
# -------------------------------------------------------

echo ""
echo "=== Radio regulatory + rfkill ==="

rfkill unblock wifi || true
iw reg set US || true
echo "  Regulatory domain: US"

# -------------------------------------------------------
# Phase 3 — Transition NetworkManager → systemd-networkd
# -------------------------------------------------------

echo ""
echo "=== Transitioning to systemd-networkd ==="

systemctl enable systemd-networkd
systemctl start systemd-networkd

if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "  Stopping NetworkManager..."
    systemctl stop NetworkManager || true
fi
systemctl disable NetworkManager 2>/dev/null || true

networkctl reload 2>/dev/null || true
networkctl reconfigure eth0 2>/dev/null || true

echo "  systemd-networkd active"
echo "  eth0 holding current IP — SSH connection stable"

sleep 3

cat > /etc/systemd/network/10-eth0.network << EOF
[Match]
Name=eth0

[Network]
DHCP=yes

[DHCP]
ClientIdentifier=mac
SendHostname=yes
EOF

networkctl reload 2>/dev/null || true
echo "  eth0 switched to DHCP — lease will renew on next expiry"

# -------------------------------------------------------
# Phase 4 — Configure wlan2 for AP mode
# -------------------------------------------------------

echo ""
echo "=== Configuring AP interface (${AP_IF}) ==="

if ip link show "${AP_IF}" >/dev/null 2>&1; then
    ip link set "${AP_IF}" down || true
    sleep 1
    iw dev "${AP_IF}" set type managed || true
    iw dev "${AP_IF}" set power_save off || true
    sleep 1
    ip link set "${AP_IF}" up || true
    echo "  ${AP_IF} configured"
else
    echo "  ${AP_IF} not present yet — will be available after reboot"
fi

# -------------------------------------------------------
# Phase 5 — hostapd
# -------------------------------------------------------

echo ""
echo "=== Configuring hostapd ==="

mkdir -p /etc/hostapd

cat > /etc/hostapd/hostapd.conf << EOF
interface=${AP_IF}
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=6
country_code=US
ieee80211n=1
wmm_enabled=1
auth_algs=1

wpa=2
wpa_passphrase=${PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

echo "  hostapd.conf written"

if grep -q "^DAEMON_CONF=" /etc/default/hostapd 2>/dev/null; then
    sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi

mkdir -p /etc/systemd/system/hostapd.service.d

cat > /etc/systemd/system/hostapd.service.d/birddog.conf << EOF
[Unit]
After=systemd-networkd.service

[Service]
ExecStartPre=/usr/sbin/rfkill unblock wifi
EOF

systemctl unmask hostapd
systemctl enable hostapd
echo "  hostapd enabled"

# -------------------------------------------------------
# Phase 6 — dnsmasq
# -------------------------------------------------------

echo ""
echo "=== Configuring dnsmasq ==="

systemctl stop dnsmasq 2>/dev/null || true
rm -f /etc/dnsmasq.conf

cat > /etc/dnsmasq.conf << EOF
# BirdDog AP DHCP server
interface=${AP_IF}
bind-dynamic
dhcp-range=10.10.10.50,10.10.10.150,255.255.255.0,24h
EOF

systemctl enable dnsmasq
echo "  dnsmasq enabled"

# -------------------------------------------------------
# Phase 7 — Reload and start services
# -------------------------------------------------------

echo ""
echo "=== Starting AP services ==="

systemctl daemon-reload

if ip link show "${AP_IF}" >/dev/null 2>&1; then

    for i in 1 2 3; do
        systemctl restart hostapd && break
        echo "  hostapd retry $i..."
        sleep 3
    done

    for i in 1 2 3; do
        systemctl restart dnsmasq && break
        echo "  dnsmasq retry $i..."
        sleep 3
    done

else
    echo "  ${AP_IF} not present — services will start automatically after reboot"
fi

# -------------------------------------------------------
# Phase 8 — MAVLink bridge (ELRS backpack → BDM AP)
# -------------------------------------------------------

echo ""
echo "=== MAVLink Bridge Setup ==="

# Auto-skip when called from device_configure (BIRDDOG_CONFIGURE=1)
# Operator runs 'birddog mavlink' manually when backpack is present
if [[ "${BIRDDOG_CONFIGURE:-0}" == "1" ]]; then
    echo "  Auto-skipped during configure — run: birddog mavlink"
    MAVLINK_INPUT="SKIP"
else
    echo ""
    echo "  The ELRS TX backpack broadcasts MAVLink telemetry over WiFi."
    echo "  This bridges wlan0 to the BirdDog AP so Mission Planner"
    echo "  on the AP network receives drone telemetry automatically."
    echo ""
    echo "  [UID]  enter the 6-digit code from your backpack"
    echo "  [SSID] enter the full network name manually"
    echo "  [SKIP] skip MAVLink bridge setup"
    echo ""
    read -r -p "  Choice: " MAVLINK_INPUT
fi

if [[ "$MAVLINK_INPUT" == "SKIP" ]]; then
    echo "  MAVLink bridge skipped"
else
    # Build SSID
    if [[ "$MAVLINK_INPUT" =~ ^[0-9a-fA-F]{6}$ ]]; then
        ELRS_SSID="${ELRS_SSID_BASE} ${MAVLINK_INPUT}"
        echo "  SSID : $ELRS_SSID"
    else
        ELRS_SSID="$MAVLINK_INPUT"
        echo "  SSID : $ELRS_SSID (manual)"
    fi

    # Unblock wlan0
    rfkill unblock wifi 2>/dev/null || true

    # Write wpa_supplicant config for the backpack
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

    # Bring wlan0 up and connect — no internet check, no default route
    ip link set wlan0 up 2>/dev/null || true

    echo "  Connecting to $ELRS_SSID ..."
    wpa_supplicant -B -i wlan0 -c "$WPA_CONF" -P /tmp/birddog_elrs_wpa.pid 2>/dev/null || true

    # Request DHCP on wlan0 with high metric so it never becomes default route
    dhclient -1 -timeout 8 -pf /tmp/birddog_elrs_dhcp.pid wlan0 2>/dev/null || true

    # Verify connection
    WLAN0_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet )[^/]+' | head -1)

    if [[ -z "$WLAN0_IP" ]]; then
        echo ""
        echo "  WARNING: Could not connect to $ELRS_SSID"
        echo "  Check UID/SSID and run: birddog mavlink"
        echo "  wlan0 left unblocked — reboot to reset"
    else
        echo "  Connected — wlan0 IP: $WLAN0_IP"

        # Remove any default route via wlan0 — we only want to forward, not route internet through it
        ip route del default dev wlan0 2>/dev/null || true

        # Enable IP forwarding
        echo 1 > /proc/sys/net/ipv4/ip_forward

        # Forward MAVLink UDP ports between wlan0 and wlan2
        # 14550 — backpack sends telemetry
        # 14555 — Mission Planner sends commands
        iptables -A FORWARD -i wlan0 -o wlan2 -p udp --dport 14550 -j ACCEPT
        iptables -A FORWARD -i wlan2 -o wlan0 -p udp --dport 14555 -j ACCEPT
        iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
        iptables -t nat -A POSTROUTING -o wlan2 -j MASQUERADE

        # Save state for birddog mavlink status command
        mkdir -p /opt/birddog/bdm
        cat > "$MAVLINK_CONF" << EOF
ELRS_SSID="${ELRS_SSID}"
WLAN0_IP="${WLAN0_IP}"
MAVLINK_ACTIVE=1
EOF

        echo ""
        echo "  MAVLink bridge active"
        echo "    wlan0  : $WLAN0_IP (ELRS backpack)"
        echo "    wlan2  : 10.10.10.1 (BirdDog AP)"
        echo "    Ports  : UDP 14550 (telemetry) / 14555 (commands)"
        echo "    Connect Mission Planner to BirdDog AP → UDP 14550"
    fi
fi

# -------------------------------------------------------
# Verification
# -------------------------------------------------------

echo ""
echo "=== Verification ==="

echo "--- networkd managed interfaces ---"
networkctl list 2>/dev/null || true

echo ""
echo "--- eth0 address ---"
ip addr show eth0 | grep "inet " || echo "  eth0: no address yet (DHCP re-acquiring)"

if ip link show "${AP_IF}" >/dev/null 2>&1; then
    echo ""
    echo "--- ${AP_IF} address ---"
    ip addr show "${AP_IF}" | grep "inet " || echo "  ${AP_IF}: no address yet"

    echo ""
    echo "--- hostapd ---"
    systemctl is-active hostapd && echo "  hostapd: OK" || echo "  hostapd: not running"

    echo ""
    echo "--- dnsmasq ---"
    systemctl is-active dnsmasq && echo "  dnsmasq: OK" || echo "  dnsmasq: not running"
fi

echo ""
echo "================================="
echo "BirdDog AP Setup Complete"
echo "================================="
echo ""
echo "Interface layout:"
echo "  eth0  → DHCP (management / SSH)"
echo "  wlan1 → mesh backbone"
echo "  wlan2 → AP ${AP_IP} (SSID: ${SSID})"
echo ""
echo "AP clients: 10.10.10.50 – 10.10.10.150"
echo "Dashboard : http://10.10.10.1"
echo ""
echo "Install log: $LOG"
echo ""
