#!/bin/bash
set -e

echo "====================================="
echo "BirdDog Device Configuration"
echo "====================================="

CURRENT_HOSTNAME=$(hostname)

echo ""
echo "Detected current hostname: $CURRENT_HOSTNAME"

read -rp "Do you want to keep current hostname? (y/n): " KEEP_HOST

if [[ "$KEEP_HOST" =~ ^[Yy]$ ]]; then
    HOSTNAME_INPUT="$CURRENT_HOSTNAME"
else
    read -rp "Enter new hostname (bdm-xx or bdc-xx): " HOSTNAME_INPUT

    if [[ ! "$HOSTNAME_INPUT" =~ ^bd[cm]-[0-9]{2}$ ]]; then
        echo "Invalid hostname format"
        exit 1
    fi

    sudo hostnamectl set-hostname "$HOSTNAME_INPUT"
fi

NODE_NUM=$(echo "$HOSTNAME_INPUT" | grep -oE '[0-9]{2}')

if [[ -z "$NODE_NUM" ]]; then
    echo "Hostname must end in number"
    exit 1
fi

MESH_IP="10.10.20.$((NODE_NUM*10))"

echo ""
echo "Final hostname: $HOSTNAME_INPUT"
echo "Mesh IP: $MESH_IP"

echo ""
echo "[Step 1] Disable cloud-init hosts management"

sudo sed -i 's/^manage_etc_hosts:.*/manage_etc_hosts: false/' /etc/cloud/cloud.cfg || true

echo ""
echo "[Step 2] Rebuild deterministic mesh hosts table"

TMP_HOSTS="/tmp/birddog_hosts"

cat <<EOF > $TMP_HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME_INPUT

# IPv6
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
echo "[Step 3] Run role installer"

if [[ "$HOSTNAME_INPUT" == bdm-* ]]; then
    bash /opt/birddog/bdm/bdm_initial_setup.sh
    bash /opt/birddog/bdm/bdm_AP_setup.sh
    bash /opt/birddog/bdm/bdm_mediamtx_setup.sh
    bash /opt/birddog/bdm/bdm_web_setup.sh
else
    bash /opt/birddog/bdc/bdc_fresh_install_setup.sh
fi

echo ""
echo "[Step 4] Install mesh runtime"

bash /opt/birddog/mesh/add_mesh_network.sh "$HOSTNAME_INPUT"

echo ""
echo "====================================="
echo "Configuration Complete"
echo "System will reboot"
echo "====================================="

sleep 3
sudo reboot
