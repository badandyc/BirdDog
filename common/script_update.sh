#!/bin/bash
set -e
set -o pipefail

mkdir -p /opt/birddog

LOG="/opt/birddog/install_ap.log"
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

# -------------------------------------------------------
# Phase 1 — Write all network config files FIRST
# before touching any running services.
# This keeps eth0 / SSH alive during the transition.
# -------------------------------------------------------

echo ""
echo "=== Writing network configuration ==="

mkdir -p /etc/systemd/network

# eth0 — DHCP, management interface (SSH lives here)
cat > /etc/systemd/network/10-eth0.network << EOF
[Match]
Name=eth0

[Network]
DHCP=yes
EOF

# wlan1 — mesh backbone, managed by birddog-mesh.service
# networkd should not touch it — unmanaged here
cat > /etc/systemd/network/20-wlan1.network << EOF
[Match]
Name=wlan1

[Network]
DHCP=no
LinkLocalAddressing=no
EOF

# wlan2 — AP interface, static IP
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
# Write config first, then switch — minimises eth0 downtime
# -------------------------------------------------------

echo ""
echo "=== Transitioning to systemd-networkd ==="

# Enable networkd before stopping NM so there's minimal gap
systemctl enable systemd-networkd
systemctl start systemd-networkd

# Now stop NetworkManager — eth0 will briefly lose its address
# then networkd will re-acquire via DHCP
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "  Stopping NetworkManager..."
    systemctl stop NetworkManager || true
fi
systemctl disable NetworkManager 2>/dev/null || true

# Trigger networkd to pick up eth0 immediately
networkctl reload 2>/dev/null || true
networkctl reconfigure eth0 2>/dev/null || true

echo "  systemd-networkd active"
echo "  NOTE: eth0 DHCP re-acquiring — SSH may briefly drop and reconnect"

# -------------------------------------------------------
# Phase 4 — Configure wlan2 for AP mode
# At this point in first-run flow the radio mapping hasn't
# run yet (that's post-reboot), so wlan2 may not exist by
# name. We attempt setup but don't block on it.
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
    echo "  (radio mapping assigns wlan2 to Edimax adapter at boot)"
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

# Point /etc/default/hostapd at our config (legacy path, belt+suspenders)
if grep -q "^DAEMON_CONF=" /etc/default/hostapd 2>/dev/null; then
    sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi

# Single drop-in: ordering + rfkill unblock before start
mkdir -p /etc/systemd/system/hostapd.service.d

cat > /etc/systemd/system/hostapd.service.d/birddog.conf << EOF
[Unit]
After=systemd-networkd.service birddog-radio-map.service

[Service]
ExecStartPre=/usr/sbin/rfkill unblock wifi
EOF

# unmask MUST come before enable — Pi OS ships hostapd masked
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

# Only attempt to start if interface exists (post-reboot it will)
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
