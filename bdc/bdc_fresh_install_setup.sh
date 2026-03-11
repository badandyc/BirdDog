#!/bin/bash
set -e

LOG="/opt/birddog/bdc/install_bdc.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog BDC Installer"
echo "================================="
date

NEW_HOSTNAME="$1"
BDM_HOST="$2"
STREAM_NAME="$3"

if [[ -z "$NEW_HOSTNAME" || -z "$BDM_HOST" || -z "$STREAM_NAME" ]]; then
    echo "BDC installer requires hostname, BDM hostname and stream name"
    exit 1
fi

echo ""
echo "=== Node Configuration ==="
echo "BDC Hostname : $NEW_HOSTNAME"
echo "BDM Host     : $BDM_HOST"
echo "Stream Name  : $STREAM_NAME"

mkdir -p /opt/birddog/bdc

cat <<EOF > /opt/birddog/bdc/bdc.conf
BDC_HOSTNAME="$NEW_HOSTNAME"
BDM_HOST="$BDM_HOST"
STREAM_NAME="$STREAM_NAME"
EOF

echo "Configuration saved."


echo ""
echo "=== Camera Verification Test ==="

TEST_FILE="/opt/birddog/test_capture.h264"
rm -f "$TEST_FILE"

echo "Capturing 5 second camera test..."

if rpicam-vid -t 5000 --nopreview -o "$TEST_FILE"; then
    echo "Camera capture command completed."
else
    echo "Camera capture command failed."
fi

if [[ -f "$TEST_FILE" ]]; then
    FILE_SIZE=$(stat -c%s "$TEST_FILE")
else
    FILE_SIZE=0
fi

echo "Captured file size: $FILE_SIZE bytes"

if [[ "$FILE_SIZE" -gt 0 ]]; then
    echo "Camera test: PASS (video data captured)"
else
    echo "Camera test: FAIL (no video data)"
fi


echo ""
echo "=== Installing Stream Script ==="

cat <<EOF > /usr/local/bin/birddog-stream.sh
#!/bin/bash
set -e

PIPE=/tmp/birddog_stream.h264
rm -f \$PIPE
mkfifo \$PIPE

trap "rm -f \$PIPE" EXIT

echo "Starting camera capture..."

rpicam-vid -t 0 --nopreview \
--width 640 --height 480 \
--framerate 30 \
--intra 30 --inline \
-o \$PIPE &

sleep 1

echo "Starting RTSP stream..."

ffmpeg \
-use_wallclock_as_timestamps 1 \
-f h264 -i \$PIPE \
-c:v copy \
-fflags +genpts \
-rtsp_transport tcp \
-f rtsp rtsp://$BDM_HOST:8554/$STREAM_NAME
EOF

chmod +x /usr/local/bin/birddog-stream.sh


echo ""
echo "=== Creating Stream Service ==="

cat <<EOF > /etc/systemd/system/birddog-stream.service
[Unit]
Description=BirdDog Camera Stream
After=network-online.target

[Service]
ExecStart=/usr/local/bin/birddog-stream.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-stream.service


echo ""
echo "=== Installing Mesh Subsystem ==="
bash /opt/birddog/mesh/add_mesh_network.sh "$NEW_HOSTNAME"


echo ""
echo "================================="
echo "BirdDog BDC Installation Complete"
echo "Node   : $NEW_HOSTNAME"
echo "Stream : rtsp://$BDM_HOST:8554/$STREAM_NAME"
echo "================================="
echo ""
