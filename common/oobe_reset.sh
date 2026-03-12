#!/bin/bash
set -e
set -o pipefail

mkdir -p /opt/birddog

LOG="/opt/birddog/oobe_reset.log"
exec > >(tee -a "$LOG") 2>&1

echo "====================================="
echo "BirdDog Factory Reset (OOBE)"
echo "====================================="
date

if [[ "$EUID" -ne 0 ]]; then
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

step() {
    echo ""
    echo "=== $1 ==="
}

svc_stop_disable() {
    SVC="$1"

    if systemctl list-unit-files | grep -q "^$SVC"; then
        if systemctl is-active "$SVC" >/dev/null 2>&1; then
            echo "Stopping $SVC (ACTIVE)"
            systemctl stop "$SVC"
        else
            echo "$SVC already stopped"
        fi

        if systemctl is-enabled "$SVC" >/dev/null 2>&1; then
            echo "Disabling $SVC (ENABLED)"
            systemctl disable "$SVC"
        else
            echo "$SVC already disabled"
        fi
    else
        echo "$SVC not present"
    fi
}

remove_path() {
    if [[ -e "$1" ]]; then
        echo "Removing $1"
        rm -rf "$1"
    else
        echo "$1 already clean"
    fi
}

step "Stopping / Disabling BirdDog services"

svc_stop_disable birddog-mesh.service
svc_stop_disable birddog-stream.service
svc_stop_disable mediamtx.service
svc_stop_disable hostapd.service
svc_stop_disable dnsmasq.service
svc_stop_disable nginx.service

step "Removing runtime helper scripts"

remove_path /usr/local/bin/birddog-mesh-join.sh
remove_path /usr/local/bin/birddog-stream.sh

step "Clearing BirdDog runtime state"

remove_path /opt/birddog/logs
remove_path /opt/birddog/mesh
remove_path /opt/birddog/radio
remove_path /opt/birddog/web
remove_path /opt/birddog/bdc/bdc.conf

mkdir -p /opt/birddog/logs
mkdir -p /opt/birddog/mesh
mkdir -p /opt/birddog/radio
mkdir -p /opt/birddog/web

step "Resetting hostname"

OLD_HOST=$(hostname)
hostnamectl set-hostname birddog
hostname birddog
echo "Hostname: $OLD_HOST → $(hostname)"

step "Resetting hosts table"

cat <<EOF > /etc/hosts
127.0.0.1 localhost
127.0.1.1 birddog

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

echo "/etc/hosts rewritten"

step "Removing network configs"

remove_path /etc/systemd/network
remove_path /etc/dnsmasq.conf
remove_path /etc/hostapd
remove_path /etc/systemd/system/hostapd.service.d

step "Reloading systemd"

systemctl daemon-reload
echo "systemd daemon-reload complete"

step "Normalizing radio interface modes"

for IFACE in wlan0 wlan1 wlan2; do
    if ip link show "$IFACE" >/dev/null 2>&1; then
        echo "Normalizing $IFACE"
        ip link set "$IFACE" down || true
        iw dev "$IFACE" set type managed || true
    else
        echo "$IFACE not present"
    fi
done

echo ""
echo "Current radio state:"
iw dev || true

step "Restarting Avahi clean"

remove_path /var/lib/avahi-daemon
systemctl restart avahi-daemon
echo "Avahi restarted"

step "Final verification snapshot"

echo "Hostname: $(hostname)"
echo ""
echo "BirdDog directory layout:"
ls -R /opt/birddog | head -50
echo ""
echo "Enabled BirdDog-related services:"
systemctl list-unit-files | grep -E "birddog|mediamtx|hostapd|dnsmasq" || true

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
