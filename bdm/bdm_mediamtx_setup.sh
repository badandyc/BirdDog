#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash /opt/birddog/bdm/bdm_mediamtx_setup.sh"
  exit 1
fi

INSTALL_DIR="/opt/birddog/mediamtx"

echo "=== Verifying MediaMTX binary ==="

if [ ! -f "$INSTALL_DIR/mediamtx" ]; then
  echo "ERROR: MediaMTX binary not found at $INSTALL_DIR/mediamtx"
  exit 1
fi

echo "=== Creating mediamtx user ==="
id -u mediamtx &>/dev/null || useradd -r -s /usr/sbin/nologin mediamtx

echo "=== Writing deterministic configuration ==="

cat > "$INSTALL_DIR/mediamtx.yml" <<EOF
logLevel: info
logDestinations: [stdout]

###############################################
# Authentication (open – isolated appliance)

authMethod: internal
authInternalUsers:
  - user: any
    ips: []
    permissions:
      - action: publish
      - action: read
      - action: playback
      - action: api
      - action: metrics
      - action: pprof

###############################################
# Control API

api: true
apiAddress: :9997
apiAllowOrigins: ['*']

###############################################
# RTSP ingest

rtsp: true
rtspAddress: :8554

###############################################
# Disable unused protocols

rtmp: false
hls: false
srt: false
metrics: false
pprof: false
playback: false

###############################################
# WebRTC viewers

webrtc: true
webrtcAddress: :8889
webrtcAllowOrigins: ['*']

###############################################
# Default path behavior

pathDefaults:
  source: publisher
  overridePublisher: true

paths:
  all_others:
EOF

chown -R mediamtx:mediamtx "$INSTALL_DIR"

echo "=== Creating systemd service ==="

cat > /etc/systemd/system/mediamtx.service <<EOF
[Unit]
Description=MediaMTX Server
After=network-online.target
Wants=network-online.target

[Service]
User=mediamtx
Group=mediamtx
ExecStart=$INSTALL_DIR/mediamtx $INSTALL_DIR/mediamtx.yml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "=== Enabling and starting service ==="

systemctl daemon-reload
systemctl enable mediamtx
systemctl restart mediamtx

echo "=== DONE ==="

systemctl status mediamtx --no-pager
