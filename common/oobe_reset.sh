#!/bin/bash
set -e

mkdir -p /opt/birddog

LOG="/opt/birddog/oobe_reset.log"
exec > >(tee -a "$LOG") 2>&1

echo "====================================="
echo "BirdDog Factory Reset (OOBE)"
echo "====================================="
date

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo bash /opt/birddog/common/oobe_reset.sh"
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
echo "=== Disabling BirdDog services ==="

systemctl disable birddog-mesh.service 2>/dev/null || true
systemctl disable birddog-stream.service 2>/dev/null || true
systemctl disable mediamtx.service 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true


echo ""
echo "=== Removing runtime helper scripts ==="

rm -f /usr/local/bin/birddog-mesh-join.sh
rm -f /usr/local/bin/birddog-stream.sh


echo ""
echo "=== Clearing BirdDog runtime state ==="

rm -rf /opt/birddog/logs/*
rm -rf /opt/birddog/mesh/*
rm -rf /opt/birddog/radio/*
rm -rf /opt/birddog/web/*
rm -f /opt/birddog/bdc/bdc.conf


echo ""
echo "=== Resetting hostname ==="

hostnamectl set-hostname birddog
hostname birddog


echo ""
echo "=== Resetting hosts table ==="

cat <<EOF > /etc/hosts
127.0.0.1 localhost
127.0.1.1 birddog

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF


echo ""
echo "=== Removing network configs ==="

rm -f /etc/systemd/network/*.network
rm -f /etc/dnsmasq.conf
rm -rf /etc/hostapd/*
rm -rf /etc/systemd/system/hostapd.service.d/*


echo ""
echo "=== Reloading systemd ==="

systemctl daemon-reload


echo ""
echo "=== Normalizing radio interface modes ==="

ip link set wlan1 down 2>/dev/null || true
ip link set wlan2 down 2>/dev/null || true

iw dev wlan1 set type managed 2>/dev/null || true
iw dev wlan2 set type managed 2>/dev/null || true


echo ""
echo "=== Restarting Avahi clean ==="

rm -rf /var/lib/avahi-daemon/* 2>/dev/null || true
systemctl restart avahi-daemon 2>/dev/null || true


echo ""
echo "====================================="
echo "BirdDog OOBE Reset Complete"
echo "====================================="
echo ""
echo "Node ready for:"
echo "    sudo birddog configure"
echo ""
echo "Log saved to:"
echo "    $LOG"
echo ""
