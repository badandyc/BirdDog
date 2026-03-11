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

* user: any
  ips: []
  permissions:

  * action: publish
  * action: read
  * action: playback
  * action: api

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

chown -R mediamtx:mediamtx "$INSTALL_DIR"_
