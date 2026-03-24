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
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>BirdDog</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }

body {
    background: #0a0a0a;
    color: #ccc;
    font-family: monospace;
    font-size: 13px;
    height: 100dvh;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    user-select: none;
}

header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 6px 12px;
    background: #141414;
    border-bottom: 1px solid #222;
    flex-shrink: 0;
    gap: 8px;
}

header strong { font-size: 14px; }

#status {
    color: #555;
    font-size: 11px;
    flex: 1;
    text-align: center;
}

button {
    background: #222;
    color: #aaa;
    border: 1px solid #333;
    padding: 4px 10px;
    cursor: pointer;
    font-family: monospace;
    font-size: 12px;
    border-radius: 3px;
    touch-action: manipulation;
}
button:active { background: #2a2a2a; color: #fff; }

/* ── grid viewport ── */
#viewport {
    flex: 1;
    overflow: hidden;
    position: relative;
}

#pages {
    display: flex;
    height: 100%;
    transition: transform 0.3s ease;
    will-change: transform;
}

.page {
    min-width: 100%;
    height: 100%;
    display: grid;
    gap: 2px;
    padding: 2px;
    grid-template-columns: repeat(2, 1fr);
    grid-template-rows: repeat(2, 1fr);
}

/* single tile full page */
.page.single {
    grid-template-columns: 1fr;
    grid-template-rows: 1fr;
}

/* portrait single column */
@media (orientation: portrait) and (max-width: 600px) {
    .page {
        grid-template-columns: 1fr;
        grid-template-rows: repeat(4, 1fr);
    }
}

/* ── tile ── */
.tile {
    position: relative;
    background: #111;
    overflow: hidden;
    border-radius: 3px;
}

.tile iframe {
    width: 100%;
    height: 100%;
    border: none;
    display: block;
}

.tile-empty {
    display: flex;
    align-items: center;
    justify-content: center;
    color: #2a2a2a;
    font-size: 11px;
    letter-spacing: 1px;
    text-transform: uppercase;
    height: 100%;
}

/* ── overlay ── */
.overlay {
    position: absolute;
    top: 0; left: 0; right: 0;
    pointer-events: none;
    z-index: 10;
    padding: 6px 8px;
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    background: linear-gradient(to bottom, rgba(0,0,0,0.65) 0%, transparent 100%);
}

.tile-name {
    font-size: 11px;
    color: #ddd;
    font-weight: bold;
    letter-spacing: 0.5px;
}

.tile-badge {
    font-size: 10px;
    padding: 2px 6px;
    border-radius: 10px;
    font-weight: bold;
    letter-spacing: 0.5px;
}
.badge-live  { background: rgba(30,160,30,0.85); color: #fff; }
.badge-dead  { background: rgba(120,30,30,0.85);  color: #aaa; }

.overlay-bottom {
    position: absolute;
    bottom: 0; left: 0; right: 0;
    pointer-events: none;
    z-index: 10;
    padding: 6px 8px;
    display: flex;
    justify-content: flex-end;
    background: linear-gradient(to top, rgba(0,0,0,0.55) 0%, transparent 100%);
}

.tile-ts {
    font-size: 9px;
    color: #555;
}

/* ── dots ── */
#dots {
    display: flex;
    justify-content: center;
    gap: 6px;
    padding: 5px 0;
    flex-shrink: 0;
    background: #0a0a0a;
}

.dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: #333;
    transition: background 0.2s;
}
.dot.active { background: #666; }

/* ── fullscreen tile ── */
.tile.fullscreen {
    position: fixed !important;
    top: 0; left: 0;
    width: 100vw !important;
    height: 100dvh !important;
    z-index: 1000;
    border-radius: 0;
}
</style>
</head>
<body>

<header>
    <strong>BirdDog</strong>
    <span id="status">loading...</span>
    <button ontouchstart="" onclick="refresh()">Refresh</button>
</header>

<div id="viewport">
    <div id="pages"></div>
</div>

<div id="dots"></div>

<script>
const PAGE_SIZE    = 4;
const REFRESH_MS   = 15000;
const SWIPE_THRESH = 50;
const DBL_TAP_MS   = 300;

let allSlots   = [];
let currentPage = 0;
let totalPages  = 0;
let refreshTimer = null;
let touchStartX  = 0;
let touchStartY  = 0;
let fullscreenTile = null;
let lastTapTime  = {};
let lastTapEl    = {};

async function getActiveStreams() {
    try {
        const r = await fetch('/api/v3/paths/list');
        const d = await r.json();
        const active = new Set();
        (d.items || []).forEach(i => { if (i.ready) active.add(i.name); });
        return active;
    } catch(e) { return null; }
}

function buildSlots(active) {
    // Build slot list from active streams + any cams that were previously live
    const known = new Set([...allSlots, ...(active || [])]);
    // Always include cam01-cam04 as baseline, plus any discovered streams
    for (let i = 1; i <= 4; i++) known.add('cam' + String(i).padStart(2,'0'));
    // Add any active streams
    if (active) active.forEach(n => known.add(n));
    return [...known].sort();
}

function renderPages(active) {
    const host   = window.location.hostname;
    const slots  = buildSlots(active);
    const pages  = document.getElementById('pages');
    const dotsEl = document.getElementById('dots');

    totalPages = Math.ceil(slots.length / PAGE_SIZE);
    if (currentPage >= totalPages) currentPage = 0;

    pages.innerHTML = '';
    dotsEl.innerHTML = '';

    for (let p = 0; p < totalPages; p++) {
        const pageEl = document.createElement('div');
        pageEl.className = 'page' + (slots.length === 1 ? ' single' : '');

        const batch = slots.slice(p * PAGE_SIZE, (p + 1) * PAGE_SIZE);

        batch.forEach(name => {
            const isLive = active && active.has(name);
            const tile   = document.createElement('div');
            tile.className = 'tile';
            tile.dataset.name = name;

            // overlay top
            const ov = document.createElement('div');
            ov.className = 'overlay';
            ov.innerHTML = `
                <span class="tile-name">${name}</span>
                <span class="tile-badge ${isLive ? 'badge-live' : 'badge-dead'}">${isLive ? 'LIVE' : 'NO SIGNAL'}</span>
            `;

            // overlay bottom
            const ovb = document.createElement('div');
            ovb.className = 'overlay-bottom';
            ovb.innerHTML = `<span class="tile-ts">${new Date().toLocaleTimeString()}</span>`;

            if (isLive) {
                const frame = document.createElement('iframe');
                frame.src   = `http://${host}:8889/${name}`;
                frame.allow = 'autoplay';
                tile.appendChild(frame);
            } else {
                const empty = document.createElement('div');
                empty.className = 'tile-empty';
                empty.textContent = name + ' — no signal';
                tile.appendChild(empty);
            }

            tile.appendChild(ov);
            tile.appendChild(ovb);
            attachTileEvents(tile);
            pageEl.appendChild(tile);
        });

        pages.appendChild(pageEl);

        // dot
        const dot = document.createElement('div');
        dot.className = 'dot' + (p === currentPage ? ' active' : '');
        dot.onclick = () => goToPage(p);
        dotsEl.appendChild(dot);
    }

    updatePagePosition(false);
}

function updatePagePosition(animate) {
    const pages = document.getElementById('pages');
    pages.style.transition = animate ? 'transform 0.3s ease' : 'none';
    pages.style.transform  = `translateX(-${currentPage * 100}%)`;

    document.querySelectorAll('.dot').forEach((d, i) => {
        d.classList.toggle('active', i === currentPage);
    });
}

function goToPage(p) {
    if (p < 0 || p >= totalPages) return;
    currentPage = p;
    updatePagePosition(true);
}

// ── swipe ──
const vp = document.getElementById('viewport');

vp.addEventListener('touchstart', e => {
    touchStartX = e.touches[0].clientX;
    touchStartY = e.touches[0].clientY;
}, { passive: true });

vp.addEventListener('touchend', e => {
    if (fullscreenTile) return;
    const dx = e.changedTouches[0].clientX - touchStartX;
    const dy = e.changedTouches[0].clientY - touchStartY;
    if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > SWIPE_THRESH) {
        dx < 0 ? goToPage(currentPage + 1) : goToPage(currentPage - 1);
    }
}, { passive: true });

// ── double tap fullscreen ──
function attachTileEvents(tile) {
    tile.addEventListener('touchend', e => {
        const name = tile.dataset.name;
        const now  = Date.now();
        if (lastTapEl[name] === tile && now - (lastTapTime[name] || 0) < DBL_TAP_MS) {
            toggleFullscreen(tile);
            lastTapTime[name] = 0;
        } else {
            lastTapTime[name] = now;
            lastTapEl[name]   = tile;
        }
    }, { passive: true });

    // desktop double click
    tile.addEventListener('dblclick', () => toggleFullscreen(tile));
}

function toggleFullscreen(tile) {
    if (fullscreenTile === tile) {
        tile.classList.remove('fullscreen');
        fullscreenTile = null;
    } else {
        if (fullscreenTile) fullscreenTile.classList.remove('fullscreen');
        tile.classList.add('fullscreen');
        fullscreenTile = tile;
    }
}

// tap fullscreen to exit on mobile
document.addEventListener('touchend', e => {
    if (!fullscreenTile) return;
    if (!fullscreenTile.contains(e.target)) return;
    // let double-tap handler deal with it
}, { passive: true });

// ── refresh ──
async function refresh() {
    clearTimeout(refreshTimer);
    document.getElementById('status').textContent = 'refreshing...';

    const active = await getActiveStreams();
    const now    = new Date().toLocaleTimeString();
    const count  = active ? active.size : 0;

    renderPages(active);

    document.getElementById('status').textContent =
        active === null
            ? 'API unreachable'
            : `${count} live — ${now}`;

    refreshTimer = setTimeout(refresh, REFRESH_MS);
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
