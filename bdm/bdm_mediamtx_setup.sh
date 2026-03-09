#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash /opt/birddog/bdm/bdm_mediamtx_setup.sh"
  exit 1
fi

INSTALL_DIR="/opt/birddog/mediamtx"
BINARY="$INSTALL_DIR/mediamtx"
CONFIG="$INSTALL_DIR/mediamtx.yml"

echo "=== Verifying MediaMTX installation ==="

if [ ! -f "$BINARY" ]; then
  echo "ERROR: MediaMTX binary not found at $BINARY"
  exit 1
fi

chmod +x "$BINARY"

echo "=== Creating mediamtx user ==="
id -u mediamtx >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin mediamtx

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

echo "=== Setting ownership ==="
chown -R mediamtx:mediamtx "$INSTALL_DIR"

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

echo "=== Reloading systemd ==="
systemctl daemon-reload

echo "=== Enabling service ==="
systemctl enable mediamtx

echo "=== Starting MediaMTX ==="
systemctl restart mediamtx

echo "=== Service status ==="
systemctl status mediamtx --no-pager
