#!/bin/bash
set -e
set -o pipefail

mkdir -p /opt/birddog/logs
mkdir -p /opt/birddog/mediamtx

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG="/opt/birddog/logs/install_mediamtx_${TIMESTAMP}.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog MediaMTX Setup"
echo "================================="
date

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo bash /opt/birddog/bdm/bdm_mediamtx_setup.sh"
    exit 1
fi

INSTALL_DIR="/opt/birddog/mediamtx"
BINARY="$INSTALL_DIR/mediamtx"
CONFIG="$INSTALL_DIR/mediamtx.yml"

# -------------------------------------------------------
# Verify binary
# -------------------------------------------------------

echo ""
echo "=== Verifying MediaMTX binary ==="

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: MediaMTX binary not found at $BINARY"
    echo "Run birddog install first."
    exit 1
fi

chmod +x "$BINARY"
echo "  Binary OK: $BINARY"

# -------------------------------------------------------
# Service user
# -------------------------------------------------------

echo ""
echo "=== Service user ==="

if id -u mediamtx >/dev/null 2>&1; then
    echo "  User 'mediamtx' already exists"
else
    useradd -r -s /usr/sbin/nologin mediamtx
    echo "  User 'mediamtx' created"
fi

# -------------------------------------------------------
# Configuration
# -------------------------------------------------------

echo ""
echo "=== Writing configuration ==="

# Detect eth0 IP for WebRTC ICE candidate locking
ETH0_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet )[^/]+' | head -1)
if [[ -z "$ETH0_IP" ]]; then
    echo "  WARNING: eth0 IP not found — WebRTC will use all interfaces"
    WEBRTC_UDP_ADDR=":8189"
else
    echo "  eth0 IP detected: $ETH0_IP"
    WEBRTC_UDP_ADDR="${ETH0_IP}:8189"
fi

cat > "$CONFIG" << EOF
logLevel: info
logDestinations: [stdout]

# Timeouts — increased for mesh link latency and low fps streams
readTimeout: 30s
writeTimeout: 30s
writeQueueSize: 512

# Allow any client to publish or read — fleet is trusted
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

# Disabled protocols — not needed for BirdDog
rtmp: false
hls: false
srt: false
metrics: false
pprof: false
playback: false

webrtc: true
webrtcAddress: :8889
webrtcLocalUDPAddress: ${WEBRTC_UDP_ADDR}
webrtcAllowOrigins: ['*']
webrtcICEServers2: []

pathDefaults:
  source: publisher
  overridePublisher: true

paths:
  all_others:
EOF

echo "  Config written: $CONFIG"

# -------------------------------------------------------
# Ownership
# -------------------------------------------------------

chown -R mediamtx:mediamtx "$INSTALL_DIR"

# -------------------------------------------------------
# Systemd service
# -------------------------------------------------------

echo ""
echo "=== Creating systemd service ==="

cat > /etc/systemd/system/mediamtx.service << EOF
[Unit]
Description=BirdDog MediaMTX RTSP/WebRTC Server
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mediamtx
systemctl restart mediamtx

# -------------------------------------------------------
# Verification
# -------------------------------------------------------

echo ""
echo "=== Verification ==="

sleep 2

if systemctl is-active --quiet mediamtx; then
    echo "  mediamtx : running"
else
    echo "  mediamtx : NOT running — check: journalctl -u mediamtx"
fi

echo ""
echo "--- Listening ports ---"
ss -lntp | grep -E '8554|8889|9997' || echo "  (ports not yet open)"

echo ""
echo "--- API test ---"
curl -s --connect-timeout 3 http://localhost:9997/v3/paths/list 2>/dev/null \
    && echo "" \
    || echo "  API not responding yet — service may still be starting"

echo ""
echo "================================="
echo "MediaMTX Setup Complete"
echo "================================="
echo ""
echo "  RTSP  : rtsp://$(hostname).local:8554/<stream>"
echo "  WebRTC: http://$(hostname).local:8889/<stream>"
echo "  API   : http://$(hostname).local:9997/v3/paths/list"
echo ""
echo "Install log: $LOG"
echo ""
