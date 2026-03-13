#!/bin/bash
set -e
set -o pipefail

mkdir -p /opt/birddog

LOG="/opt/birddog/install_bdm_bootstrap.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog BDM Bootstrap"
echo "================================="
date

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root: sudo bash /opt/birddog/bdm/bdm_initial_setup.sh <bdm-##>"
  exit 1
fi

NEW_HOSTNAME="$1"

if [[ -z "$NEW_HOSTNAME" ]]; then
  echo "ERROR: Hostname argument missing."
  exit 1
fi

if [[ ! "$NEW_HOSTNAME" =~ ^bdm-[0-9]{2}$ ]]; then
  echo "ERROR: Invalid hostname format."
  echo "Expected: bdm-01, bdm-02, etc."
  exit 1
fi

echo ""
echo "=== Disable cloud-init if present ==="

if [[ -d /etc/cloud ]]; then
  echo "Disabling cloud-init hostname control"
  touch /etc/cloud/cloud-init.disabled
fi

echo ""
echo "=== Setting hostname ==="

OLD_HOST=$(hostname)

hostnamectl set-hostname "$NEW_HOSTNAME"
echo "$NEW_HOSTNAME" > /etc/hostname

if grep -q "^127.0.1.1" /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1    $NEW_HOSTNAME/" /etc/hosts
else
  echo "127.0.1.1    $NEW_HOSTNAME" >> /etc/hosts
fi

hostname "$NEW_HOSTNAME"

echo "Hostname: $OLD_HOST → $NEW_HOSTNAME"

echo ""
echo "=== Resetting Avahi state ==="

rm -rf /var/lib/avahi-daemon/* || true

systemctl enable avahi-daemon
systemctl restart avahi-daemon

echo ""
echo "=== Verification ==="

echo "--- Hostname ---"
hostname

echo ""
echo "--- Hosts entry ---"
grep 127.0.1.1 /etc/hosts

echo ""
echo "--- Avahi active ---"
systemctl is-active avahi-daemon || true

echo ""
echo "================================="
echo "BDM Bootstrap Complete"
echo "================================="
echo "Hostname: $NEW_HOSTNAME"
echo ""
echo "Install log saved to:"
echo "$LOG"
