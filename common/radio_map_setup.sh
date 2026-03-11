#!/bin/bash
set -e

echo "================================="
echo "BirdDog Radio Mapping Installer"
echo "================================="

INSTALL_PATH="/usr/local/bin/birddog-radio-map.sh"
SERVICE_PATH="/etc/systemd/system/birddog-radio-map.service"
LOG_DIR="/opt/birddog/radio"
LOG_FILE="$LOG_DIR/radio_map.log"
MARKER="/run/birddog-radio-map.done"

mkdir -p "$LOG_DIR"

cat <<'EOF' > $INSTALL_PATH
#!/bin/bash

LOG="/opt/birddog/radio/radio_map.log"
MARKER="/run/birddog-radio-map.done"

exec >> "$LOG" 2>&1

echo ""
echo "================================="
echo "Radio Mapping Runtime $(date)"
echo "================================="

sleep 5

INTERFACES=$(iw dev | awk '$1=="Interface"{print $2}')

if [[ -z "$INTERFACES" ]]; then
    echo "No wireless interfaces detected — exiting"
    exit 0
fi

declare -A TARGET_MAP

for IF in $INTERFACES
do
    DRIVER=$(ethtool -i $IF 2>/dev/null | awk '/driver:/{print $2}')

    echo "Detected $IF driver=$DRIVER"

    if [[ "$DRIVER" == "brcmfmac" ]]; then
        TARGET="wlan0"

    elif [[ "$DRIVER" == "mt76x2u" ]]; then
        TARGET="wlan1"

    else
        TARGET="wlan2"
    fi

    TARGET_MAP[$IF]=$TARGET
done

echo "Applying mapping..."

# temp rename to avoid collisions
for IF in "${!TARGET_MAP[@]}"
do
    ip link set $IF down || true
    ip link set $IF name temp_$IF || true
done

# final rename
for IF in "${!TARGET_MAP[@]}"
do
    TARGET=${TARGET_MAP[$IF]}
    ip link set temp_$IF name $TARGET || true
done

echo ""
echo "Final layout:"
for IF in wlan0 wlan1 wlan2
do
    if ip link show $IF >/dev/null 2>&1; then
        DRIVER=$(ethtool -i $IF 2>/dev/null | awk '/driver:/{print $2}')
        echo "$IF → $DRIVER"
    fi
done

touch "$MARKER"

echo "Radio mapping complete."
EOF

chmod +x $INSTALL_PATH

cat <<EOF > $SERVICE_PATH
[Unit]
Description=BirdDog Radio Mapping
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-radio-map.service

echo ""
echo "================================="
echo "Radio mapping service installed"
echo "Runs automatically at boot"
echo "Log: $LOG_FILE"
echo "================================="
