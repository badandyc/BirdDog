#!/bin/bash
set -e
set -o pipefail

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -E bash /opt/birddog/common/oobe_reset.sh "$@"
fi

BIRDDOG_ROOT="/opt/birddog"
LOG="$BIRDDOG_ROOT/oobe_reset.log"
mkdir -p "$BIRDDOG_ROOT"

exec > >(tee -a "$LOG") 2>&1

echo "====================================="
echo "BirdDog Field Reset (OOBE)"
echo "====================================="
date

echo ""
echo "WARNING:"
echo "  This wipes all BirdDog node configuration."
echo "  Scripts and binaries are preserved."
echo "  Node will need birddog configure to become operational."
echo ""

read -r -p "Type RESET to continue: " CONFIRM

if [[ "$CONFIRM" != "RESET" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

step() { echo ""; echo "• $1"; }

svc_stop_disable() {
    local SVC="$1"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SVC}"; then
        systemctl is-active "$SVC" >/dev/null 2>&1 \
            && { systemctl stop "$SVC"; echo "  stopped  $SVC"; } \
            || echo "  already stopped  $SVC"
        systemctl disable "$SVC" 2>/dev/null \
            && echo "  disabled $SVC" \
            || echo "  already disabled $SVC"
    else
        echo "  not present  $SVC"
    fi
}

remove_path() {
    local TARGET="$1"
    if [[ -e "$TARGET" ]]; then
        rm -rf "$TARGET"
        echo "  removed  $TARGET"
    else
        echo "  clean    $TARGET"
    fi
}

# -------------------------------------------------------
# Step 1 — Stop and disable BirdDog services
# -------------------------------------------------------

step "Stopping BirdDog services"

svc_stop_disable birddog-mesh.service
svc_stop_disable birddog-stream.service
svc_stop_disable mediamtx.service
svc_stop_disable hostapd.service
svc_stop_disable dnsmasq.service
svc_stop_disable nginx.service

systemctl mask hostapd 2>/dev/null && echo "  masked   hostapd.service" || true

# -------------------------------------------------------
# Step 2 — Remove runtime scripts
# -------------------------------------------------------

step "Removing runtime scripts"

remove_path /usr/local/bin/birddog-mesh-join.sh
remove_path /usr/local/bin/birddog-stream.sh

for SVC in birddog-mesh birddog-stream mediamtx; do
    rm -f "/etc/systemd/system/${SVC}.service"
    rm -f "/etc/systemd/system/multi-user.target.wants/${SVC}.service"
done

# -------------------------------------------------------
# Step 3 — Clear runtime state
# -------------------------------------------------------

step "Clearing runtime state"

remove_path "$BIRDDOG_ROOT/logs"
remove_path "$BIRDDOG_ROOT/web"
remove_path "$BIRDDOG_ROOT/bdc/bdc.conf"

if [[ -d "$BIRDDOG_ROOT/mesh" ]]; then
    find "$BIRDDOG_ROOT/mesh" -mindepth 1 \
        ! -name "add_mesh_network.sh" \
        -exec rm -rf {} + 2>/dev/null || true
    echo "  mesh runtime cleared (installer preserved)"
fi

mkdir -p "$BIRDDOG_ROOT"/{logs,web,mesh}

# -------------------------------------------------------
# Step 4 — Clear role-specific config
# -------------------------------------------------------

step "Clearing role configuration"

if [[ -d /etc/hostapd ]]; then
    rm -f /etc/hostapd/*.conf 2>/dev/null || true
    echo "  hostapd config cleared"
fi

remove_path /etc/systemd/system/hostapd.service.d
remove_path /etc/dnsmasq.conf
remove_path /etc/systemd/network

# Restore eth0 DHCP so management access survives reboot
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-eth0.network << 'EOF'
[Match]
Name=eth0

[Network]
DHCP=yes

[DHCP]
ClientIdentifier=mac
SendHostname=yes
EOF
echo "  eth0 DHCP config restored"

# Ensure systemd-networkd manages eth0 — stop NetworkManager so it
# can't grab eth0 before networkd does
systemctl stop NetworkManager 2>/dev/null || true
systemctl disable NetworkManager 2>/dev/null || true
systemctl enable systemd-networkd 2>/dev/null || true
systemctl restart systemd-networkd 2>/dev/null || true
sleep 2
networkctl reconfigure eth0 2>/dev/null || true
echo "  systemd-networkd enabled — NetworkManager disabled"
echo "  eth0 reconfigured"

# -------------------------------------------------------
# Step 5 — Reset hostname
# -------------------------------------------------------

step "Resetting hostname"

OLD_HOST=$(hostname)
echo "birddog" > /etc/hostname
hostnamectl set-hostname birddog

cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
127.0.1.1 birddog

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

echo "  $OLD_HOST → birddog"

# -------------------------------------------------------
# Step 6 — Restart avahi
# -------------------------------------------------------

step "Restarting avahi"

rm -rf /var/lib/avahi-daemon/* 2>/dev/null || true
systemctl restart avahi-daemon
echo "  avahi restarted"

# -------------------------------------------------------
# Step 7 — Bring radio interfaces to clean baseline
# -------------------------------------------------------

step "Resetting radio interfaces"

for IFACE in wlan1 wlan2; do
    if ip link show "$IFACE" >/dev/null 2>&1; then
        ip link set "$IFACE" down 2>/dev/null || true
        iw dev "$IFACE" set type managed 2>/dev/null || true
        echo "  $IFACE → down (managed)"
    else
        echo "  $IFACE → not present"
    fi
done

# -------------------------------------------------------
# Step 8 — Reload systemd
# -------------------------------------------------------

step "Reloading systemd"
systemctl daemon-reload
echo "  done"

# -------------------------------------------------------
# Verification snapshot
# -------------------------------------------------------

step "Reset verification"

echo ""
echo "  Hostname : $(hostname)"

echo ""
echo "  Radios:"
for IFACE in wlan0 wlan1 wlan2; do
    if ip link show "$IFACE" >/dev/null 2>&1; then
        DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk '/driver:/{print $2}')
        STATE=$(ip link show "$IFACE" | awk '/state/{print $9}')
        echo "    $IFACE  driver=$DRIVER  state=$STATE"
    else
        echo "    $IFACE  not present"
    fi
done

echo ""
echo "  Services:"
for SVC in birddog-mesh birddog-stream mediamtx hostapd dnsmasq nginx birddog_day; do
    STATE=$(systemctl is-enabled "${SVC}.service" 2>/dev/null || true)
    [[ -z "$STATE" ]] && STATE="not-found"
    if [[ "$SVC" == "dnsmasq" || "$SVC" == "nginx" ]] && [[ "$STATE" == "enabled" ]]; then
        STATE="enabled (by design)"
    fi
    if [[ "$SVC" == "hostapd" ]] && [[ "$STATE" == "masked" ]]; then
        STATE="masked (by design)"
    fi
    echo "    ${SVC}  →  $STATE"
done

echo ""
echo "====================================="
echo "Field Reset Complete"
echo "====================================="
echo ""
echo "Node ready for: birddog configure"
echo ""
echo "====================================="
echo "⚠  REBOOT REQUIRED"
echo "====================================="
echo ""
echo "  Some reset changes do not take effect until"
echo "  the node is rebooted. Reboot before running"
echo "  birddog configure."
echo ""
echo "    sudo reboot"
echo ""
echo "Full log: $LOG"
echo ""
