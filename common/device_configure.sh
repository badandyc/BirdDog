#!/bin/bash
set -e

echo "====================================="
echo "BirdDog Device Configuration"
echo "====================================="

CURRENT_HOSTNAME=$(hostname)

echo ""
echo "Current hostname detected: $CURRENT_HOSTNAME"

read -rp "Keep current hostname + BDM association? (y/n): " KEEP

if [[ "$KEEP" =~ ^[Yy]$ ]]; then

    HOSTNAME_INPUT="$CURRENT_HOSTNAME"

    # try to recover previous BDM + stream config
    BDM_HOST=$(grep BDM_HOST /opt/birddog/version/VERSION 2>/dev/null | cut -d= -f2 || true)
    STREAM_NAME=$(grep STREAM_NAME /opt/birddog/version/VERSION 2>/dev/null | cut -d= -f2 || true)

    echo "Reusing hostname: $HOSTNAME_INPUT"
    [[ -n "$BDM_HOST" ]] && echo "Reusing BDM host: $BDM_HOST"
    [[ -n "$STREAM_NAME" ]] && echo "Reusing stream: $STREAM_NAME"

else

    read -rp "Enter hostname (bdm-xx or bdc-xx): " HOSTNAME_INPUT

    if [[ ! "$HOSTNAME_INPUT" =~ ^bd[cm]-[0-9]{2}$ ]]; then
        echo "Invalid hostname format"
        exit 1
    fi

    sudo hostnamectl set-hostname "$HOSTNAME_INPUT"

    if [[ "$HOSTNAME_INPUT" == bdc-* ]]; then
        read -rp "Enter BDM hostname: " BDM_HOST
        read -rp "Enter stream name: " STREAM_NAME
    fi

fi

NODE_NUM=$(echo "$HOSTNAME_INPUT" | grep -oE '[0-9]{2}')
MESH_IP="10.10.20.$((NODE_NUM*10))"

echo ""
echo "Final hostname: $HOSTNAME_INPUT"
echo "Mesh IP: $MESH_IP"

echo ""
echo "[Hosts] Disable cloud-init control"
sudo sed -i 's/^manage_etc_hosts:.*/manage_etc_hosts: false/' /etc/cloud/cloud.cfg || true

echo "[Hosts] Rebuilding deterministic mesh table"

TMP_HOSTS="/tmp/birddog_hosts"

cat <<EOF > $TMP_HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME_INPUT

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

# BirdDog Mesh Nodes
EOF

for slot in $(seq 1 25)
do
    IP="10.10.20.$((slot*10))"
    NAME="bdc-$(printf "%02d" $slot)"
    echo "$IP $NAME" >> $TMP_HOSTS
done

sudo cp $TMP_HOSTS /etc/hosts

echo ""
echo "[Role Install]"

if [[ "$HOSTNAME_INPUT" == bdm-* ]]; then

    bash /opt/birddog/bdm/bdm_initial_setup.sh
    bash /opt/birddog/bdm/bdm_AP_setup.sh
    bash /opt/birddog/bdm/bdm_mediamtx_setup.sh
    bash /opt/birddog/bdm/bdm_web_setup.sh

else

    bash /opt/birddog/bdc/bdc_fresh_install_setup.sh "$BDM_HOST" "$STREAM_NAME"

fi

echo ""
echo "[Mesh Install]"
bash /opt/birddog/mesh/add_mesh_network.sh "$HOSTNAME_INPUT"

echo ""
echo "====================================="
echo "Configuration Complete — Rebooting"
echo "====================================="

sleep 3
sudo reboot
