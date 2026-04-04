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

AP_IF="wlan_ap"
AP_IP="10.10.10.1/24"
SSID="BirdDog"
PASSPHRASE="StrongPass123"

# -------------------------------------------------------
# Phase 1 — Network config files
# -------------------------------------------------------

echo ""
echo "=== Writing network configuration ==="

# NetworkManager is purged in the golden image — eth0 is managed by ifupdown
# (/etc/network/interfaces). We only need a systemd-networkd file for wlan_ap
# so it gets the static AP IP. wlan_mesh_5 is managed entirely by batman-adv
# and must not be touched by systemd-networkd.

mkdir -p /etc/systemd/network

cat > /etc/systemd/network/30-wlan_ap.network << EOF
[Match]
Name=${AP_IF}

[Network]
Address=${AP_IP}
ConfigureWithoutCarrier=yes
LinkLocalAddressing=no
EOF

echo "  wlan_ap network config written"

# Ensure systemd-networkd is running to manage wlan_ap static IP
systemctl enable systemd-networkd 2>/dev/null || true
systemctl start systemd-networkd 2>/dev/null || true
networkctl reload 2>/dev/null || true

echo "  systemd-networkd running"
echo "  eth0 managed by ifupdown — SSH connection unaffected"

# -------------------------------------------------------
# Phase 2 — Regulatory domain
# -------------------------------------------------------

echo ""
echo "=== Radio regulatory ==="

# Set regulatory domain for wlan_ap (RTL8192CU, 2.4 GHz AP).
# rfkill userspace tool is not available — unblocking is handled
# in the hostapd service drop-in via sysfs.
iw reg set US || true
echo "  Regulatory domain: US"

# -------------------------------------------------------
# Phase 3 — Configure wlan_ap for AP mode
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
# Phase 4 — hostapd
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

# Unblock only the rtl8192cu (wlan_ap) via sysfs rfkill.
# rfkill userspace tool is not installed — sysfs is used directly.
# Broad 'rfkill unblock wifi' is intentionally avoided — it would
# unblock the onboard brcmfmac which must stay blocked.
cat > /etc/systemd/system/hostapd.service.d/birddog.conf << 'EOF'
[Unit]
After=systemd-networkd.service birddog-block-onboard-wifi.service

[Service]
ExecStartPre=/bin/bash -c '\
    for rf in /sys/class/rfkill/rfkill*/; do \
        drv=$(readlink -f "$rf/device/driver" 2>/dev/null | xargs basename 2>/dev/null); \
        if [[ "$drv" == "rtl8192cu" ]]; then \
            idx=$(cat "$rf/index" 2>/dev/null); \
            echo 0 > "/sys/class/rfkill/rfkill${idx}/soft" 2>/dev/null || true; \
            echo "unblocked rfkill${idx} (rtl8192cu)"; \
        fi; \
    done'
EOF

systemctl unmask hostapd
systemctl enable hostapd
echo "  hostapd enabled"

# -------------------------------------------------------
# Phase 5 — dnsmasq
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
# Phase 6 — Reload and start services
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
# Phase 7 — MAVLink bridge note
# -------------------------------------------------------

echo ""
echo "=== MAVLink Bridge ==="
echo "  Run 'birddog mavlink' when ELRS backpack is present"

# -------------------------------------------------------
# Verification
# -------------------------------------------------------

echo ""
echo "=== Verification ==="

echo "--- eth0 address ---"
ip addr show eth0 | grep "inet " || echo "  eth0: no address yet"

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
echo "  eth0       → DHCP (management / SSH)"
echo "  wlan_mesh_5 → batman-adv mesh backbone → bat0"
echo "  wlan_ap    → AP ${AP_IP} (SSID: ${SSID})"
echo ""
echo "AP clients: 10.10.10.50 – 10.10.10.150"
echo "Dashboard : http://10.10.10.1"
echo ""
echo "Install log: $LOG"
echo ""
