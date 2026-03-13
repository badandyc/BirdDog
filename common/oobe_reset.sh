#!/bin/bash
set -e
set -o pipefail

mkdir -p /opt/birddog

LOG="/opt/birddog/oobe_reset.log"

# stdout = operator
# fd3 = logfile (full trace)
exec 3>>"$LOG"
BASH_XTRACEFD=3
set -x

echo "====================================="
echo "BirdDog Factory Reset (OOBE)"
echo "====================================="
date | tee /dev/fd/3

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
    echo "• $1"
}

svc_stop_disable() {

    SVC="$1"

    if systemctl list-unit-files | grep -q "^$SVC"; then

        if systemctl is-active "$SVC" >/dev/null 2>&1; then
            echo "   stopping $SVC"
            systemctl stop "$SVC"
        else
            echo "   $SVC already stopped"
        fi

        if systemctl is-enabled "$SVC" >/dev/null 2>&1; then
            echo "   disabling $SVC"
            systemctl disable "$SVC"
        else
            echo "   $SVC already disabled"
        fi

    else
        echo "   $SVC not present"
    fi
}

remove_path() {

    TARGET="$1"

    if [[ -e "$TARGET" ]]; then
        echo "   removing $TARGET"
        rm -rf "$TARGET"
    else
        echo "   $TARGET already clean"
    fi
}

step "Stopping and disabling BirdDog services"

svc_stop_disable birddog-mesh.service
svc_stop_disable birddog-stream.service
svc_stop_disable mediamtx.service
svc_stop_disable hostapd.service
svc_stop_disable dnsmasq.service
svc_stop_disable nginx.service

step "Removing runtime helper scripts"

remove_path /usr/local/bin/birddog-mesh-join.sh
remove_path /usr/local/bin/birddog-stream.sh

step "Clearing runtime state"

remove_path /opt/birddog/logs
remove_path /opt/birddog/radio
remove_path /opt/birddog/web
remove_path /opt/birddog/bdc/bdc.conf

echo "   cleaning mesh runtime (preserving lifecycle)"

MESH_DIR="/opt/birddog/mesh"
PRESERVE="$MESH_DIR/add_mesh_network.sh"

if [[ -d "$MESH_DIR" ]]; then

    if [[ -f "$PRESERVE" ]]; then
        echo "   preserving add_mesh_network.sh"
    fi

    find "$MESH_DIR" -mindepth 1 ! -path "$PRESERVE" -exec rm -rf {} +

else
    echo "   mesh directory not present"
fi

mkdir -p /opt/birddog/logs
mkdir -p /opt/birddog/mesh
mkdir -p /opt/birddog/radio
mkdir -p /opt/birddog/web

step "Resetting hostname"

OLD_HOST=$(hostname)
hostnamectl set-hostname birddog
hostname birddog
echo "   $OLD_HOST → $(hostname)"

step "Rewriting hosts table"

cat <<EOF > /etc/hosts
127.0.0.1 localhost
127.0.1.1 birddog

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

step "Removing network configuration"

remove_path /etc/systemd/network
remove_path /etc/dnsmasq.conf
remove_path /etc/hostapd
remove_path /etc/systemd/system/hostapd.service.d

step "Reloading systemd"

systemctl daemon-reload

step "Normalizing radio modes"

for IFACE in wlan0 wlan1 wlan2; do
    if ip link show "$IFACE" >/dev/null 2>&1; then
        echo "   normalizing $IFACE"
        ip link set "$IFACE" down || true
        iw dev "$IFACE" set type managed || true
    fi
done

step "Restarting Avahi clean"

rm -rf /var/lib/avahi-daemon/* 2>/dev/null || true
systemctl restart avahi-daemon

step "Verification snapshot"

hostname
iw dev || true
systemctl list-unit-files | grep -E "birddog|mediamtx|hostapd|dnsmasq" || true

set +x

echo ""
echo "====================================="
echo "BirdDog OOBE Reset Complete"
echo "====================================="
echo ""
echo "Node ready for:"
echo "    sudo birddog configure"
echo ""
echo "Full trace saved to:"
echo "    $LOG"
echo ""
