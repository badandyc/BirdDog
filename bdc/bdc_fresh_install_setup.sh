#!/bin/bash
set -e

LOG="/opt/birddog/bdc/install_bdc.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog BDC Installer"
echo "================================="
date

NEW_HOSTNAME="$1"
BDM_HOST_ARG="$2"

NODE_NUM=$(echo "$NEW_HOSTNAME" | grep -oE '[0-9]{2}')
STREAM_NAME="cam${NODE_NUM}"

echo ""
echo "=== Node Configuration ==="

if [[ -n "$BDM_HOST_ARG" ]]; then
    BDM_HOST="$BDM_HOST_ARG"
    echo "Reusing BDM: $BDM_HOST"
else
    read -p "Enter BDM hostname (without .local): " BDM_NAME
    BDM_HOST="${BDM_NAME}.local"
fi

# persist config
mkdir -p /opt/birddog/bdc
cat <<EOF > /opt/birddog/bdc/bdc.conf
BDC_HOSTNAME="$NEW_HOSTNAME"
BDM_HOST="$BDM_HOST"
STREAM_NAME="$STREAM_NAME"
EOF


# echo ""
# echo "=== Camera Verification Test ==="
#
# TEST_FILE="/opt/birddog/test_capture.h264"
# rm -f "$TEST_FILE"
#
# echo "Capturing 5 second camera test..."
#
# if rpicam-vid -t 5000 --nopreview -o "$TEST_FILE"; then
#     echo "Camera capture command completed."
# else
#     echo "Camera capture command failed."
# fi
#
# if [[ -f "$TEST_FILE" ]]; then
#     FILE_SIZE=$(stat -c%s "$TEST_FILE")
# else
#     FILE_SIZE=0
# fi
#
# echo "Captured file size: $FILE_SIZE bytes"
#
# if [[ "$FILE_SIZE" -gt 0 ]]; then
#     echo "Camera test: PASS (video data captured)"
# else
#     echo "Camera test: FAIL (no video data)"
# fi


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

echo "Starting camera capture..."

rpicam-vid -t 0 --nopreview \
--width \$WIDTH --height \$HEIGHT \
--framerate \$FPS \
--intra \$FPS --inline \
-o \$PIPE &

sleep 1

echo "Starting RTSP stream to \$BDM_HOST..."

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
echo "=== Installing Mesh Subsystem ==="
bash /opt/birddog/mesh/add_mesh_network.sh "$NEW_HOSTNAME"


echo ""
echo "================================="
echo "BirdDog BDC Installation Complete"
echo "Node: $NEW_HOSTNAME"
echo "Stream: rtsp://$BDM_HOST:8554/$STREAM_NAME"
echo "================================="
echo ""
