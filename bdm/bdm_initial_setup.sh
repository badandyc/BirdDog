#!/bin/bash
set -e

mkdir -p /opt/birddog

LOG="/opt/birddog/install_bdm_bootstrap.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog BDM Bootstrap"
echo "================================="
date

if [ "$EUID" -ne 0 ]; then
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
echo "=== Disable cloud-init hostname control ==="

if [ -d /etc/cloud ]; then
echo "Disabling cloud-init host management..."
sed -i 's/^manage_etc_hosts:.*/manage_etc_hosts: false/' /etc/cloud/cloud.cfg || true
touch /etc
