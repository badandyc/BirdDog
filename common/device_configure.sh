#!/bin/bash
set -e
set -o pipefail

echo "====================================="
echo "BirdDog Device Configuration"
echo "====================================="

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -E bash /opt/birddog/common/device_configure.sh "$@"
fi

BDC_CONFIG="/opt/birddog/bdc/bdc.conf"
CURRENT_HOST=$(hostname)

REUSE_ALL=0

echo ""
echo "-------------------------------------"
echo "Phase 1 — Existing Configuration Check"
echo "-------------------------------------"

if [[ "$CURRENT_HOST" =~ ^bdc-[0-9]{2}$ && -f "$BDC_CONFIG" ]]; then

    source "$BDC_CONFIG"

    if [[ -n "$BDM_HOST" ]]; then
        echo ""
        echo "Existing configuration detected:"
        echo "BDC Hostname : $CURRENT_HOST"
        echo "BDM Host     : $BDM_HOST"
        echo ""

        read -r -p "Keep current BDC and BDM settings? (y/n): " KEEP_ALL

        if [[ "$KEEP_ALL" =~ ^[Yy]$ ]]; then
            HOSTNAME_INPUT="$CURRENT_HOST"
            REUSE_ALL=1
        fi
    fi
fi

echo ""
echo "-------------------------------------"
echo "Phase 2 — Hostname Selection"
echo "-------------------------------------"

if [[ "$REUSE_ALL" != "1" ]]; then

    while true
    do
        read -r -p "Enter BirdDog hostname (bdm-## or bdc-##): " HOSTNAME_INPUT

        [[ -z "$HOSTNAME_INPUT" ]] && continue

        if [[ "$HOSTNAME_INPUT" =~ ^bd[cm]-[0-9]{2}$ ]]; then
            break
        fi

        echo "Invalid hostname format (must be bdm-01 or bdc-01)"
    done

fi

ROLE=$(echo "$HOSTNAME_INPUT" | cut -d- -f1)
NODE_NUM=$(echo "$HOSTNAME_INPUT" | cut -d- -f2)
STREAM_NAME="cam${NODE_NUM}"

echo ""
echo "Applying hostname: $HOSTNAME_INPUT"

hostnamectl set-hostname "$HOSTNAME_INPUT"
hostname "$HOSTNAME_INPUT"

echo ""
echo "-------------------------------------"
echo "Phase 3 — Avahi + Host Table Setup"
echo "-------------------------------------"

if [[ -f /etc/cloud/cloud.cfg ]]; then
    sed -i 's/^manage_etc_hosts:.*/manage_etc_hosts: false/' /etc/cloud/cloud.cfg || true
fi

rm -rf /var/lib/avahi-daemon/* 2>/dev/null || true
systemctl restart avahi-daemon 2>/dev/null || true

TMP_HOSTS="/tmp/birddog_hosts"

cat <<EOF > "$TMP_HOSTS"
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
    BDC_NAME="bdc-$(printf "%02d" $slot)"
    BDM_NAME="bdm-$(printf "%02d" $slot)"

    echo "$IP $BDC_NAME" >> "$TMP_HOSTS"
    echo "$IP $BDM_NAME" >> "$TMP_HOSTS"
done

mv "$TMP_HOSTS" /etc/hosts

echo ""
echo "-------------------------------------"
echo "Phase 4 — Radio Mapping"
echo "-------------------------------------"

bash /opt/birddog/common/radio_map_setup.sh

echo ""
echo "Current Radio Layout:"
birddog radios || true

echo ""
echo "-------------------------------------"
echo "Phase 5 — Role Installer"
echo "-------------------------------------"

if [[ "$ROLE" == "bdc" ]]; then

    if [[ "$REUSE_ALL" == "1" ]]; then
        echo ""
        echo "[BDC] Reusing existing configuration..."
    else

        while true
        do
            read -r -p "Enter BDM hostname (without .local): " BDM_NAME

            [[ -z "$BDM_NAME" ]] && continue

            if [[ "$BDM_NAME" =~ ^bdm-[0-9]{2}$ ]]; then
                break
            fi

            echo "Invalid BDM hostname format"
        done

        BDM_HOST="${BDM_NAME}.local"
    fi

    echo ""
    echo "[BDC] Running installer..."

    bash /opt/birddog/bdc/bdc_fresh_install_setup.sh \
        "$HOSTNAME_INPUT" \
        "$BDM_HOST" \
        "$STREAM_NAME"

elif [[ "$ROLE" == "bdm" ]]; then

    echo ""
    echo "[BDM] Running installer..."

    bash /opt/birddog/bdm/bdm_initial_setup.sh "$HOSTNAME_INPUT"
    bash /opt/birddog/bdm/bdm_AP_setup.sh
    bash /opt/birddog/bdm/bdm_mediamtx_setup.sh
    bash /opt/birddog/bdm/bdm_web_setup.sh

else
    echo "Unknown role"
    exit 1
fi

echo ""
echo "-------------------------------------"
echo "Phase 6 — Mesh Installation"
echo "-------------------------------------"

bash /opt/birddog/mesh/add_mesh_network.sh "$HOSTNAME_INPUT"

echo "Waiting for mesh service..."
sleep 3

if ! systemctl is-active --quiet birddog-mesh.service; then
    echo "ERROR: Mesh service failed to start"
    exit 1
fi

echo ""
echo "====================================="
echo "Device configuration complete."
echo "====================================="
echo ""
echo "Recommended: reboot node now"
echo ""
