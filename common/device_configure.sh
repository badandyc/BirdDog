#!/bin/bash
set -e
set -o pipefail

echo "================================="
echo "BirdDog Radio Mapping Installer"
echo "================================="

INSTALL_ONLY=0
[[ "$1" == "--install-only" ]] && INSTALL_ONLY=1

BIRDDOG_ROOT="/opt/birddog"
RADIO_DIR="$BIRDDOG_ROOT/radio"
RUNTIME_SCRIPT="/usr/local/bin/birddog-radio-map.sh"
SERVICE_FILE="/etc/systemd/system/birddog-radio-map.service"
LOG_FILE="$RADIO_DIR/radio_map.log"

mkdir -p "$RADIO_DIR"

echo ""
echo "Installing radio mapping runtime..."

cat << 'EOF' > "$RUNTIME_SCRIPT"
#!/bin/bash
set -e
set -o pipefail

LOG="/opt/birddog/radio/radio_map.log"
exec >> "$LOG" 2>&1

echo "================================="
echo "BirdDog Radio Mapping Runtime"
echo "================================="
date

ACTIVE_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')

echo "Active management interface: $ACTIVE_IF"

for IFACE in wlan0 wlan1 wlan2
do
    if ip link show "$IFACE" >/dev/null 2>&1; then

        if [[ "$IFACE" == "$ACTIVE_IF" ]]; then
            echo "Skipping active transport interface: $IFACE"
            continue
        fi

        echo "Configuring $IFACE"

        ip link set "$IFACE" down || true
        iw dev "$IFACE" set type managed || true
        ip link set "$IFACE" up || true

    else
        echo "$IFACE not present"
    fi
done

echo ""
echo "Final radio state:"
iw dev || true

echo ""
echo "Radio mapping runtime complete"
EOF

chmod +x "$RUNTIME_SCRIPT"

echo ""
echo "Installing systemd service..."

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=BirdDog Radio Mapping
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=$RUNTIME_SCRIPT
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

if [[ "$INSTALL_ONLY" -eq 1 ]]; then
    echo ""
    echo "NOTE: Radio mapping changes apply at next reboot."
    echo ""
    exit 0
fi

echo ""
echo "Manual execution requested — running runtime mapping now"
echo ""

"$RUNTIME_SCRIPT"

echo ""
echo "Radio mapping execution complete"
echo ""
