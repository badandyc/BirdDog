#!/bin/bash
set -e

mkdir -p /opt/birddog
mkdir -p /opt/birddog/mediamtx

LOG="/opt/birddog/install_mediamtx.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog MediaMTX Setup"
echo "================================="
date

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash /opt/birddog/bdm/bdm_mediamtx_setup.sh"
  exit 1
fi

INSTALL_DIR="/opt/birddog/mediamtx"
BINARY="$INSTALL_DIR/mediamtx"
CONFIG="$INSTALL_DIR/mediamtx.yml"

echo ""
echo "=== Verifying MediaMTX binary ==="

if [ ! -f "$BINARY" ]; then
  echo "ERROR: MediaMTX binary not found at:"
  echo "$BINARY"
  echo ""
  echo "Run golden image creation first."
  exit 1
fi

chmod +x "$BINARY"

echo ""
echo "=== Creating mediamtx service user ==="

if id -u mediamtx >/dev/null 2>&1; then
  echo "User 'mediamtx' already exists"
else
  useradd -r -s /usr/sbin/nologin mediamtx
fi

echo ""
echo "=== Writing configuration ==="

cat > "$CONFIG" <<EOF
logLevel: info
logDestinations: [stdout]

authMethod: internal
authInternalUsers:
  - user: any
    ips: []
    permissions:
      - action: publish
      - action: read
      - action: playback
      - action: api

api: true
apiAddress: :9997
apiAllowOrigins: ['*']

rtsp: true
rtspAddress: :8554

rtmp: false
hls: false
srt: false
metrics: false
pprof: false
playback: false

webrtc: true
webrtcAddress: :8889
webrtcAllowOrigins: ['*']

pathDefaults:
  source: publisher
  overridePublisher: true

paths:
  all_others:
EOF

echo ""
echo "=== Setting ownership ==="

chown -R mediamtx:mediamtx "$INSTALL_DIR"

echo ""
echo "=== Creating systemd service ==="

cat > /etc/systemd/system/mediamtx.service <<EOF
[Unit]
Description=BirdDog MediaMTX Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mediamtx
Group=mediamtx
WorkingDirectory=$INSTALL_DIR
ExecStart=$BINARY $CONFIG
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo ""
echo "=== Reloading systemd ==="
systemctl daemon-reload

echo ""
echo "=== Enabling MediaMTX service ==="
systemctl enable mediamtx

echo ""
echo "=== Starting MediaMTX ==="
systemctl restart mediamtx

echo ""
echo "=== Verification ==="

echo "--- Service Status ---"
systemctl status mediamtx --no-pager

echo ""
echo "--- Listening Ports ---"
ss -lntp | grep -E '8554|8889|9997' || true

echo ""
echo "--- API Test ---"
curl -s http://localhost:9997/v3/paths/list || true

echo ""
echo "================================="
echo "MediaMTX Setup Complete"
echo "================================="
echo ""
echo "RTSP Server : rtsp://<BDM-IP>:8554"
echo "WebRTC Port : 8889"
echo "API         : http://<BDM-IP>:9997"
echo ""
echo "Install log saved to:"
echo "$LOG"
