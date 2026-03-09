#!/bin/bash
set -e

LOG="/opt/birddog/install_bdm_bootstrap.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== BirdDog BDM Bootstrap ==="
date

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash /opt/birddog/bdm/bdm_initial_setup.sh"
  exit 1
fi

echo "=== Disable cloud-init if present ==="

if [ -d /etc/cloud ]; then
  echo "Disabling cloud-init..."
  touch /etc/cloud/cloud-init.disabled
fi

echo "=== Prompt for hostname ==="

read -p "Enter new hostname (e.g. bdm-01): " NEW_HOSTNAME

if [[ -z "$NEW_HOSTNAME" ]]; then
  echo "Hostname cannot be empty."
  exit 1
fi

echo "Setting hostname to $NEW_HOSTNAME"

echo "$NEW_HOSTNAME" > /etc/hostname

if grep -q "^127.0.1.1" /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1    $NEW_HOSTNAME/" /etc/hosts
else
  echo "127.0.1.1    $NEW_HOSTNAME" >> /etc/hosts
fi

hostname "$NEW_HOSTNAME"

echo "=== Resetting Avahi state ==="

rm -rf /var/lib/avahi-daemon/* || true

systemctl enable avahi-daemon
systemctl restart avahi-daemon

echo "=== Determining mesh IP ==="

HOST=$(hostname)

if [[ $HOST =~ bdm-([0-9]+) ]]; then
  ID=${BASH_REMATCH[1]}
  MESH_IP="10.10.20.$ID"
else
  echo "ERROR: Hostname must follow pattern bdm-XX"
  exit 1
fi

echo "Mesh IP will be $MESH_IP"

echo "=== Configuring mesh interface ==="

mkdir -p /etc/systemd/network

cat > /etc/systemd/network/30-mesh.network <<EOF
[Match]
Name=wlan1

[Network]
Address=${MESH_IP}/24
EOF

systemctl enable systemd-networkd
systemctl restart systemd-networkd

echo "=== Verification ==="

echo "--- Hostname ---"
hostname

echo "--- Hosts file ---"
grep 127.0.1.1 /etc/hosts

echo "--- Avahi status ---"
systemctl status avahi-daemon --no-pager

echo "--- Mesh interface config ---"
ip addr show wlan1 || true

echo "--- systemd-networkd status ---"
systemctl status systemd-networkd --no-pager

echo "=== Bootstrap complete ==="
echo "Hostname: $NEW_HOSTNAME"
echo "Mesh IP: $MESH_IP"

echo "Install log saved to: $LOG"
