#!/bin/bash
set -e

echo "====================================="
echo "BirdDog Factory Reset (OOBE)"
echo "====================================="

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo bash oobe_reset.sh"
    exit 1
fi

echo ""
echo "WARNING:"
echo "This will wipe BirdDog node configuration."
echo "Golden installer baseline will be preserved."
echo ""

read -p "Type RESET to continue: " CONFIRM

if [[ "$CONFIRM" != "RESET" ]]; then
    echo "Aborted."
    exit 1
fi


echo ""
echo "=== Stopping BirdDog services ==="

systemctl stop birddog-mesh.service 2>/dev/null || true
systemctl stop birddog-stream.service 2>/dev/null || true
systemctl stop mediamtx.service 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true


echo ""
echo "=== Disabling services ==="

systemctl disable birddog-mesh.service 2>/dev/null || true
systemctl disable birddog-stream.service 2>/dev/null || true
systemctl disable mediamtx.service 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true


echo ""
echo "=== Removing systemd unit files ==="

rm -f /etc/systemd/system/birddog-mesh.service
rm -f /etc/systemd/system/birddog-stream.service
rm -f /etc/systemd/system/mediamtx.service

systemctl daemon-reload


echo ""
echo "=== Removing runtime scripts ==="

rm -f /usr/local/bin/birddog-mesh-join.sh
rm -f /usr/local/bin/birddog-stream.sh


echo ""
echo "=== Clearing BirdDog runtime state ==="

rm -rf /opt/birddog/logs/*
rm -rf /opt/birddog/mesh/*
rm -rf /opt/birddog/radio/*
rm -rf /opt/birddog/web/*
rm -rf /opt/birddog/mediamtx/*
rm -rf /opt/birddog/version/*
rm -f /opt/birddog/bdc/bdc.conf


echo ""
echo "=== Removing mediamtx service user (if exists) ==="

userdel mediamtx 2>/dev/null || true


echo ""
echo "=== Reset hostname ==="

hostnamectl set-hostname birddog
hostname birddog

cat <<EOF > /etc/hosts
127.0.0.1 localhost
127.0.1.1 birddog

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF


echo ""
echo "=== Reset network configuration ==="

rm -f /etc/systemd/network/*.network
rm -f /etc/dnsmasq.conf
rm -rf /etc/hostapd/*
rm -rf /etc/systemd/system/hostapd.service.d/*

systemctl daemon-reexec


echo ""
echo "=== Restore DHCP client (management safety) ==="

systemctl enable dhcpcd 2>/dev/null || true
systemctl start dhcpcd 2>/dev/null || true


echo ""
echo "=== Reset radios to safe managed mode ==="

ip link set wlan1 down 2>/dev/null || true
ip link set wlan2 down 2>/dev/null || true

iw dev wlan1 set type managed 2>/dev/null || true
iw dev wlan2 set type managed 2>/dev/null || true


echo ""
echo "=== Reset Avahi state ==="

rm -rf /var/lib/avahi-daemon/* 2>/dev/null || true
systemctl restart avahi-daemon 2>/dev/null || true


echo ""
echo "====================================="
echo "BirdDog OOBE Reset Complete"
echo "Node ready for: sudo birddog configure"
echo "Recommended: reboot node now"
echo "====================================="
echo ""
