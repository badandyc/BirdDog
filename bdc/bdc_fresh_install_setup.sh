#!/bin/bash
set -e

LOG="/opt/birddog/install_bdc.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== BirdDog BDC Installer ==="
date

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo bash /opt/birddog/start.sh"
    exit 1
fi

# Hostname passed from start.sh
NEW_HOSTNAME="$1"

if [[ -z "$NEW_HOSTNAME" ]]; then
    echo "Error: hostname not provided."
    echo "Run via: sudo bash /opt/birddog/start.sh"
    exit 1
fi

echo "BDC hostname received: $NEW_HOSTNAME"

# Disable cloud-init if present
if [ -d /etc/cloud ]; then
    echo "Disabling cloud-init..."
    touch /etc/cloud/cloud-init.disabled
fi

echo "=== Enabling Avahi ==="
systemctl enable avahi-daemon
systemctl start avahi-daemon

# Verify hostname is not already on network
if avahi-resolve-host-name "$NEW_HOSTNAME.local" >/dev/null 2>&1; then
    echo "Warning: hostname already detected on network."
fi

NODE_NUM=$(echo "$NEW_HOSTNAME" | grep -oE '[0-9]+$')

if [[ -z "$NODE_NUM" ]]; then
    echo "Hostname must end in a number (e.g. bdc-01)"
    exit 1
fi

STREAM_NAME="cam$(printf "%02d" "$NODE_NUM")"

read -p "Enter BDM hostname (without .local): " BDM_NAME

if [[ -z "$BDM_NAME" ]]; then
    echo "BDM hostname cannot be empty."
    exit 1
fi

BDM_HOST="${BDM_NAME}.local"

echo "BDC Hostname: $NEW_HOSTNAME"
echo "Stream name: $STREAM_NAME"
echo "BDM target: $BDM_HOST"

systemctl restart avahi-daemon

echo ""
echo "====================================="
echo "Plug in the USB mesh WiFi adapter now."
echo "It should appear as interface: wlan1"
echo "====================================="
read -p "Press ENTER to continue..."

echo "Waiting for mesh adapter (wlan1)..."

until ip link show wlan1 >/dev/null 2>&1; do
    echo "Mesh adapter not detected yet..."
    sleep 2
done

echo "Mesh adapter detected."

echo "=== Determining mesh IP ==="

MESH_IP="10.10.20.$((NODE_NUM*10))"

echo "Mesh IP will be $MESH_IP"

mkdir -p /etc/systemd/network

cat > /etc/systemd/network/30-mesh.network <<EOF
[Match]
Name=wlan1

[Network]
Address=${MESH_IP}/24
EOF

systemctl enable systemd-networkd
systemctl restart systemd-networkd

echo "Installing stream script..."

cat <<EOF > /usr/local/bin/birddog-stream.sh
#!/bin/bash
set -e

BDM_HOST="$BDM_HOST"
STREAM_NAME="$STREAM_NAME"

WIDTH=640
HEIGHT=480
FPS=30

PIPE=/tmp/birddog_stream.h264
rm -f \$PIPE
mkfifo \$PIPE

trap "rm -f \$PIPE" EXIT

rpicam-vid -t 0 --nopreview \
--width \$WIDTH --height \$HEIGHT \
--framerate \$FPS \
--intra \$FPS --inline \
-o \$PIPE &

sleep 1

ffmpeg -use_wallclock_as_timestamps 1 \
-f h264 -i \$PIPE \
-c:v copy \
-fflags +genpts \
-rtsp_transport tcp \
-f rtsp rtsp://\$BDM_HOST:8554/\$STREAM_NAME
EOF

chmod +x /usr/local/bin/birddog-stream.sh

echo "Installing systemd service..."

cat <<EOF > /etc/systemd/system/birddog-stream.service
[Unit]
Description=BirdDog Camera Stream
After=network-online.target avahi-daemon.service
Wants=network-online.target
Requires=avahi-daemon.service

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'until getent hosts $BDM_HOST; do sleep 1; done'
ExecStart=/usr/local/bin/birddog-stream.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-stream.service

echo "=== Verification ==="

echo "--- Hostname ---"
hostname

echo "--- Mesh interface ---"
ip addr show wlan1 || true

echo "--- Stream service status ---"
systemctl status birddog-stream.service --no-pager || true

echo "=== Installation Complete ==="
echo "Mesh IP: $MESH_IP"
echo "Install log saved to: $LOG"

echo "Rebooting in 5 seconds..."
sleep 5
reboot
