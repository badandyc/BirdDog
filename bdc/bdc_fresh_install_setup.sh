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

# save config for reuse
mkdir -p /opt/birddog/bdc
cat <<EOF > /opt/birddog/bdc/bdc.conf
BDC_HOSTNAME="$NEW_HOSTNAME"
BDM_HOST="$BDM_HOST"
STREAM_NAME="$STREAM_NAME"
EOF

echo ""
echo "=== Installing Stream Script ==="

cat <<EOF > /usr/local/bin/birddog-stream.sh
#!/bin/bash
set -e

BDM_HOST="$BDM_HOST"
STREAM_NAME="$STREAM_NAME"

PIPE=/tmp/birddog_stream.h264
rm -f \$PIPE
mkfifo \$PIPE

trap "rm -f \$PIPE" EXIT

rpicam-vid -t 0 --nopreview -o \$PIPE &

sleep 1

ffmpeg -f h264 -i \$PIPE -c:v copy \
-rtsp_transport tcp \
-f rtsp rtsp://\$BDM_HOST:8554/\$STREAM_NAME
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-stream.service

echo ""
echo "=== Installing Mesh ==="
bash /opt/birddog/mesh/add_mesh_network.sh "$NEW_HOSTNAME"

echo ""
echo "BDC install complete"
