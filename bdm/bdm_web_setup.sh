#!/bin/bash
set -e
set -o pipefail

mkdir -p /opt/birddog/logs

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG="/opt/birddog/logs/install_web_${TIMESTAMP}.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog Web Dashboard Setup"
echo "================================="
date

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo bash /opt/birddog/bdm/bdm_web_setup.sh"
    exit 1
fi

WEB_DIR="/opt/birddog/web"
mkdir -p "$WEB_DIR"

# -------------------------------------------------------
# nginx config
# -------------------------------------------------------

echo ""
echo "=== Writing nginx config ==="

mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

cat > /etc/nginx/sites-available/birddog << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    root $WEB_DIR;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Proxy mediamtx API to avoid CORS issues from the dashboard
    location /api/ {
        proxy_pass http://127.0.0.1:9997/;
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/birddog \
       /etc/nginx/sites-enabled/birddog

rm -f /etc/nginx/sites-enabled/default

echo "  nginx config written"

# -------------------------------------------------------
# Dashboard
# -------------------------------------------------------

echo ""
echo "=== Writing dashboard ==="

cat > "$WEB_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BirdDog</title>
<style>

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
    background: #0a0a0a;
    color: #ccc;
    font-family: monospace;
    font-size: 13px;
    height: 100vh;
    display: flex;
    flex-direction: column;
}

header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 6px 12px;
    background: #141414;
    border-bottom: 1px solid #222;
    flex-shrink: 0;
}

header span { color: #666; }

button {
    background: #222;
    color: #aaa;
    border: 1px solid #333;
    padding: 4px 10px;
    cursor: pointer;
    font-family: monospace;
    font-size: 12px;
    border-radius: 3px;
}

button:hover { background: #2a2a2a; color: #fff; }

#status {
    color: #555;
    font-size: 11px;
}

#grid {
    display: grid;
    grid-template-columns: 640px 640px;
    grid-template-rows: 480px 480px;
    gap: 2px;
    padding: 2px;
    flex: 1;
    overflow: auto;
    justify-content: center;
    align-content: center;
}

.tile {
    position: relative;
    background: #111;
    width: 640px;
    height: 480px;
    overflow: hidden;
}

.tile-label {
    position: absolute;
    top: 6px;
    left: 8px;
    background: rgba(0,0,0,0.6);
    color: #aaa;
    font-size: 11px;
    padding: 2px 6px;
    border-radius: 2px;
    z-index: 10;
    pointer-events: none;
}

.tile-status {
    position: absolute;
    top: 6px;
    right: 8px;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #333;
    z-index: 10;
}

.tile-status.live  { background: #2d9e2d; }
.tile-status.dead  { background: #6b2020; }

.tile iframe {
    width: 640px;
    height: 480px;
    border: none;
    display: block;
}

.tile-empty {
    display: flex;
    align-items: center;
    justify-content: center;
    color: #2a2a2a;
    font-size: 12px;
    letter-spacing: 1px;
    text-transform: uppercase;
}

</style>
</head>
<body>

<header>
    <strong>BirdDog</strong>
    <span id="status">loading...</span>
    <button onclick="refresh()">Refresh</button>
</header>

<div id="grid"></div>

<script>

const SLOTS = ['cam01', 'cam02', 'cam03', 'cam04'];
const REFRESH_INTERVAL = 15000;

let refreshTimer = null;

async function getActiveStreams() {
    try {
        const r = await fetch('/api/v3/paths/list');
        const d = await r.json();
        const active = new Set();
        (d.items || []).forEach(item => {
            if (item.ready) active.add(item.name);
        });
        return active;
    } catch (e) {
        return null;
    }
}

async function refresh() {

    clearTimeout(refreshTimer);

    const status = document.getElementById('status');
    status.textContent = 'refreshing...';

    const active = await getActiveStreams();
    const grid = document.getElementById('grid');
    const host = window.location.hostname;

    if (active === null) {
        status.textContent = 'API unreachable';
        refreshTimer = setTimeout(refresh, REFRESH_INTERVAL);
        return;
    }

    let liveCount = 0;

    SLOTS.forEach(name => {

        let tile = document.getElementById('tile-' + name);
        const isLive = active.has(name);
        const hasFrame = tile && tile.querySelector('iframe');
        const hasEmpty = tile && tile.querySelector('.tile-empty');

        // Create tile if it doesn't exist yet
        if (!tile) {
            tile = document.createElement('div');
            tile.className = 'tile';
            tile.id = 'tile-' + name;

            const label = document.createElement('div');
            label.className = 'tile-label';
            label.textContent = name;

            const dot = document.createElement('div');
            dot.className = 'tile-status';

            tile.appendChild(label);
            tile.appendChild(dot);
            grid.appendChild(tile);
        }

        const dot = tile.querySelector('.tile-status');

        if (isLive) {

            liveCount++;
            dot.className = 'tile-status live';

            // Only create iframe if not already streaming — avoids reset
            if (!hasFrame) {
                const empty = tile.querySelector('.tile-empty');
                if (empty) empty.remove();

                const frame = document.createElement('iframe');
                frame.src = `http://${host}:8889/${name}`;
                frame.allow = 'autoplay';
                tile.insertBefore(frame, tile.firstChild);
            }

        } else {

            dot.className = 'tile-status dead';

            // Remove iframe if stream went offline
            if (hasFrame) {
                hasFrame.remove();
            }

            if (!hasEmpty) {
                const empty = document.createElement('div');
                empty.className = 'tile-empty';
                empty.textContent = name + ' — no signal';
                tile.insertBefore(empty, tile.firstChild);
            }

        }

    });

    const now = new Date().toLocaleTimeString();
    status.textContent = `${liveCount} / ${SLOTS.length} live — ${now}`;

    refreshTimer = setTimeout(refresh, REFRESH_INTERVAL);
}

refresh();

</script>
</body>
</html>
EOF

echo "  Dashboard written: $WEB_DIR/index.html"

# -------------------------------------------------------
# Validate and start nginx
# -------------------------------------------------------

echo ""
echo "=== Starting nginx ==="

nginx -t
systemctl enable nginx
systemctl restart nginx

# -------------------------------------------------------
# Verification
# -------------------------------------------------------

echo ""
echo "=== Verification ==="

if systemctl is-active --quiet nginx; then
    echo "  nginx : running"
else
    echo "  nginx : NOT running — check: journalctl -u nginx"
fi

echo ""
echo "--- Port 80 ---"
ss -lntp | grep ':80 ' || echo "  (not listening)"

echo ""
echo "--- Web directory ---"
ls -lh "$WEB_DIR"

echo ""
echo "================================="
echo "BirdDog Web Dashboard Ready"
echo "================================="
echo ""
echo "  Dashboard : http://$(hostname).local"
echo "  Dashboard : http://10.10.10.1"
echo ""
echo "Install log: $LOG"
echo ""
