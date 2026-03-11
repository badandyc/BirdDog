#!/bin/bash
set -e

LOG="/opt/birddog/bdc/install_bdc.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog BDC Installer"
echo "================================="
date

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo bash /opt/birddog/common/device_configure.sh"
    exit 1
fi

NEW_HOSTNAME="$1"

if [[ -z "$NEW_HOSTNAME" ]]; then
    echo "Error: hostname not provided."
    exit 1
fi

NODE_NUM=$(echo "$NEW_HOSTNAME" | grep -oE '[0-9]+$')

if [[ -z "$NODE_NUM" ]]; then
    echo "Hostname must end in a number (e.g. bdc-01)"
    exit 1
fi

CONFIG_FILE="/opt/birddog/bdc/bdc.conf"

echo ""
echo "=== Existing Configuration Check ==="

if [[ -f "$CONFIG_FILE" ]]; then

    source "$CONFIG_FILE"

    echo "Existing BDC hostname : $BDC_HOSTNAME"
    echo "Existing BDM hostname : $BDM_HOST"

    read -p "Keep existing configuration? (y/n): " KEEP_CFG

    if [[ "$KEEP_CFG" =~ ^[Yy]$ ]]; then
        NEW_HOSTNAME="$BDC_HOSTNAME"
        STREAM_NAME="$STREAM_NAME"
        BDM_HOST="$BDM_HOST"
        SKIP_PROMPTS=1
    else
        SKIP_PROMPTS=0
    fi

else
    SKIP_PROMPTS=0
fi


echo ""
echo "=== System Preparation ==="

echo "Setting system hostname..."
hostnamectl set-hostname "$NEW_HOSTNAME"

echo "Updating /etc/hosts..."
if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1   $NEW_HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1   $NEW_HOSTNAME" >> /etc/hosts
fi

if [ -d /etc/cloud ]; then
    touch /etc/cloud/cloud-init.disabled
fi

systemctl enable avahi-daemon
systemctl start avahi-daemon


echo ""
echo "=== Node Configuration ==="

if [[ "$SKIP_PROMPTS" != "1" ]]; then

    STREAM_NAME="cam$(printf "%02d" "$NODE_NUM")"

    read -p "Enter BDM hostname (without .local): " BDM_NAME
    BDM_HOST="${BDM_NAME}.local"

fi

echo "BDC Hostname : $NEW_HOSTNAME"
echo "Stream Name  : $STREAM_NAME"
echo "BDM Host     : $BDM_HOST"


echo ""
echo "=== Camera Verification Test ==="

TEST_FILE="/opt/birddog/test_capture.h264"
rm -f "$TEST_FILE"

if rpicam-vid -t 5000 --nopreview -o "$TEST_FILE"; then
    echo "Camera capture completed"
fi

FILE_SIZE=$(stat -c%s "$TEST_FILE" 2>/dev/null || echo 0)

if [[ "$FILE_SIZE" -gt 0 ]]; then
    echo "Camera test PASS"
else
    echo "Camera test FAIL"
fi


echo ""
echo "=== Installing Stream Script ==="

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

ffmpeg \
-use_wallclock_as_timestamps 1 \
-f h264 -i \$PIPE \
-c:v copy \
-fflags +genpts \
-rtsp_transport tcp \
-f rtsp rtsp://\$BDM_HOST:8554/\$STREAM_NAME
EOF

chmod +x /usr/local/bin/birddog-stream.sh


echo ""
echo "=== Creating Stream Service ==="

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


echo ""
echo "=== Saving Configuration ==="

mkdir -p /opt/birddog/bdc

cat <<EOF > "$CONFIG_FILE"
BDC_HOSTNAME="$NEW_HOSTNAME"
STREAM_NAME="$STREAM_NAME"
BDM_HOST="$BDM_HOST"
EOF


echo ""
echo "================================="
echo "BirdDog BDC Installation Complete"
echo "Node   : $NEW_HOSTNAME"
echo "Stream : rtsp://$BDM_HOST:8554/$STREAM_NAME"
echo "================================="
echo ""
echo "Rebooting in 10 seconds..."
sleep 10
#reboot -f
