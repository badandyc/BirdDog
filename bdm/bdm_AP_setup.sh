#!/bin/bash
set -e

LOG="/opt/birddog/install_ap.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== BirdDog AP Setup ==="
date

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash /opt/birddog/bdm/bdm_AP_setup.sh"
  exit 1
fi

AP_IF="wlan2"
AP_IP="10.10.10.1/24"
SSID="BirdDog"
PASSPHRASE="StrongPass123"

echo "=== Waiting for AP adapter (${AP_IF}) ==="

until ip link show ${AP_IF} >/dev/null 2>&1; do
    echo "Waiting for ${AP_IF}..."
    sleep 2
done

echo "${AP_IF} detected"


echo "=== Unblocking WiFi ==="
rfkill unblock wifi || true


echo "=== Set regulatory domain ==="
iw reg set US || true


echo "=== Disable NetworkManager (appliance mode) ==="
systemctl stop NetworkManager 2>/dev/null || true
systemctl disable NetworkManager 2>/dev/null || true


echo "=== Enable systemd-networkd ==="
systemctl enable systemd-networkd
systemctl start systemd-networkd


mkdir -p /etc/systemd/network


echo "=== Configure eth0 (DHCP for LAN access) ==="

cat > /etc/systemd/network/eth0.network <<EOF
[Match]
Name=eth0

[Network]
DHCP=yes
EOF


echo "=== Configure ${AP_IF} (Static AP IP) ==="

cat > /etc/systemd/network/${AP_IF}.network <<EOF
[Match]
Name=${AP_IF}

[Network]
Address=${AP_IP}
ConfigureWithoutCarrier=yes
EOF


echo "=== Configure hostapd ==="

cat > /etc/hostapd/hostapd.conf <<EOF
interface=${AP_IF}
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=6
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=${PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF


if grep -q "^DAEMON_CONF=" /etc/default/hostapd; then
  sed -i "s|^DAEMON_CONF=.*|DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"|" /etc/default/hostapd
else
  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi


systemctl unmask hostapd || true
systemctl enable hostapd


echo "=== Configure hostapd startup ordering ==="

mkdir -p /etc/systemd/system/hostapd.service.d

cat > /etc/systemd/system/hostapd.service.d/override.conf <<EOF
[Unit]
After=systemd-networkd.service
EOF


echo "=== Configure dnsmasq ==="

systemctl stop dnsmasq || true
rm -f /etc/dnsmasq.conf

cat > /etc/dnsmasq.conf <<EOF
interface=${AP_IF}
bind-dynamic
dhcp-range=10.10.10.50,10.10.10.150,255.255.255.0,24h
EOF

systemctl enable dnsmasq


echo "=== Ensure WiFi unblocked on boot ==="

cat > /etc/systemd/system/hostapd.service.d/rfkill.conf <<EOF
[Service]
ExecStartPre=/usr/sbin/rfkill unblock wifi
EOF


echo "=== Disable WiFi power save ==="
iw dev ${AP_IF} set power_save off || true


systemctl daemon-reload


echo "=== Restarting services ==="

systemctl restart systemd-networkd
systemctl restart hostapd
systemctl restart dnsmasq


echo "=== Verification ==="

echo "--- Interface status ---"
ip addr show ${AP_IF}

echo "--- hostapd status ---"
systemctl status hostapd --no-pager

echo "--- dnsmasq status ---"
systemctl status dnsmasq --no-pager

echo "--- Listening DHCP port ---"
ss -lntup | grep 67 || true

echo "--- WiFi interface info ---"
iw dev ${AP_IF} info || true


echo "=== DONE ==="

echo "Management:"
echo "  eth0  → DHCP"
echo "  wlan0 → optional SSH WiFi"

echo "BirdDog Networks:"
echo "  wlan1 → mesh backbone"
echo "  wlan2 → AP network (${AP_IP})"

echo ""
echo "Install log saved to:"
echo "$LOG"
