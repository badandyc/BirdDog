#!/bin/bash
set -e
set -o pipefail

mkdir -p /opt/birddog/bdc
mkdir -p /opt/birddog/logs

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG="/opt/birddog/logs/install_bdc_${TIMESTAMP}.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog BDC Installer"
echo "================================="
date

NEW_HOSTNAME="$1"
BDM_HOST="$2"
STREAM_NAME="$3"

if [[ -z "$NEW_HOSTNAME" || -z "$BDM_HOST" || -z "$STREAM_NAME" ]]; then
    echo "ERROR: BDC installer requires hostname, BDM host, and stream name"
    echo "Usage: bdc_fresh_install_setup.sh <hostname> <bdm-host> <stream-name>"
    exit 1
fi

# -------------------------------------------------------
# Save configuration
# -------------------------------------------------------

CONFIG_FILE="/opt/birddog/bdc/bdc.conf"

cat > "$CONFIG_FILE" << EOF
BDC_HOSTNAME="$NEW_HOSTNAME"
BDM_HOST="$BDM_HOST"
STREAM_NAME="$STREAM_NAME"
EOF

echo ""
echo "=== Node Configuration ==="
echo "  BDC Hostname : $NEW_HOSTNAME"
echo "  BDM Host     : $BDM_HOST"
echo "  Stream Name  : $STREAM_NAME"
echo "  Config saved : $CONFIG_FILE"

# -------------------------------------------------------
# Stream service state check
# -------------------------------------------------------

echo ""
echo "=== Stream Service State Check ==="

if systemctl is-active --quiet birddog-stream 2>/dev/null; then
    echo "Stream service already active — reinstalling with current config"
    systemctl stop birddog-stream || true
fi

# -------------------------------------------------------
# Camera verification
# -------------------------------------------------------

echo ""
echo "=== Camera Verification ==="

TEST_FILE="/opt/birddog/bdc/test_capture.h264"
rm -f "$TEST_FILE"

echo "Capturing 3 second camera test..."

CAMERA_OK=0

if rpicam-vid -t 5000 --nopreview -o "$TEST_FILE" 2>/dev/null; then
    FILE_SIZE=0
    [[ -f "$TEST_FILE" ]] && FILE_SIZE=$(stat -c%s "$TEST_FILE")

    if [[ "$FILE_SIZE" -gt 0 ]]; then
        echo "  Camera test : PASS ($FILE_SIZE bytes)"
        CAMERA_OK=1
    else
        echo "  Camera test : FAIL (file empty)"
    fi
else
    echo "  Camera test : FAIL (rpicam-vid error)"
fi

rm -f "$TEST_FILE"

if [[ "$CAMERA_OK" -eq 0 ]]; then
    echo ""
    echo "  WARNING: Camera not detected or not working"
    echo "  Stream service will be installed but may not produce video"
    echo "  Check ribbon cable and camera module, then run: birddog configure"
fi

# -------------------------------------------------------
# Write stream runtime script
# -------------------------------------------------------

echo ""
echo "=== Installing Stream Script ==="

cat > /usr/local/bin/birddog-stream.sh << 'STREAM_EOF'
#!/bin/bash

# BirdDog Camera Stream Runtime
# Captures from Pi camera and pushes RTSP to BDM mediamtx server.
# Managed by birddog-stream.service (systemd).

BDM_HOST="__BDM_HOST__"
STREAM_NAME="__STREAM_NAME__"
PIPE=/tmp/birddog_stream.h264

cleanup() {
    echo "Stream shutting down — cleaning up"
    pkill -f rpicam-vid 2>/dev/null || true
    rm -f "$PIPE"
}

trap cleanup EXIT INT TERM

# Kill any stale camera process from a previous run
pkill -f rpicam-vid 2>/dev/null || true
sleep 1

rm -f "$PIPE"
mkfifo "$PIPE"

echo "Starting camera capture..."

rpicam-vid -t 0 --nopreview \
    --width 640 --height 480 \
    --framerate 30 \
    --intra 15 --inline \
    -o "$PIPE" &

CAM_PID=$!
sleep 2

# Verify camera process is still alive before starting ffmpeg
if ! kill -0 "$CAM_PID" 2>/dev/null; then
    echo "ERROR: rpicam-vid failed to start"
    exit 1
fi

echo "Starting RTSP stream → rtsp://${BDM_HOST}:8554/${STREAM_NAME}"

ffmpeg \
    -probesize 32 \
    -analyzeduration 0 \
    -use_wallclock_as_timestamps 1 \
    -f h264 -i "$PIPE" \
    -c:v copy \
    -fflags +genpts+nobuffer \
    -flush_packets 1 \
    -rtsp_transport tcp \
    -pkt_size 1300 \
    -f rtsp "rtsp://${BDM_HOST}:8554/${STREAM_NAME}"

# ffmpeg exited — cleanup trap will fire
STREAM_EOF

# Inject node-specific values
sed -i "s|__BDM_HOST__|${BDM_HOST}|g"       /usr/local/bin/birddog-stream.sh
sed -i "s|__STREAM_NAME__|${STREAM_NAME}|g" /usr/local/bin/birddog-stream.sh

chmod +x /usr/local/bin/birddog-stream.sh

# -------------------------------------------------------
# Write systemd service
# -------------------------------------------------------

echo ""
echo "=== Creating Stream Service ==="

cat > /etc/systemd/system/birddog-stream.service << EOF
[Unit]
Description=BirdDog Camera Stream
After=network-online.target birddog-mesh.service
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/birddog-stream.sh
Restart=always
RestartSec=10
StartLimitIntervalSec=60
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-stream.service
systemctl restart birddog-stream.service

echo ""
echo "================================="
echo "BDC Installation Complete"
echo "  Node   : $NEW_HOSTNAME"
echo "  Stream : rtsp://$BDM_HOST:8554/$STREAM_NAME"
echo "  Camera : $([ $CAMERA_OK -eq 1 ] && echo OK || echo WARNING — check camera)"
echo "================================="
echo ""
echo "Install log: $LOG"
echo ""
