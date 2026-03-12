#!/bin/bash
set -e

mkdir -p /opt/birddog

LOG="/opt/birddog/install_web.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog Web Dashboard Setup"
echo "================================="
date

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo bash /opt/birddog/bdm/bdm_web_setup.sh"
    exit 1
fi

WEB_DIR="/opt/birddog/web"

echo ""
echo "=== Preparing web directory ==="
mkdir -p "$WEB_DIR"


echo ""
echo "=== Writing nginx config ==="

mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    root $WEB_DIR;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF


echo ""
echo "=== Ensuring nginx site enabled ==="

ln -sf /etc/nginx/sites-available/default \
       /etc/nginx/sites-enabled/default


echo ""
echo "=== Writing dashboard ==="

cat > "$WEB_DIR/index.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>BirdDog Dashboard</title>

<style>
body {
    background: #111;
    color: white;
    font-family: Arial, sans-serif;
    margin: 0;
    padding: 10px;
}

h1 { margin-top: 0; }

button {
    padding: 6px 12px;
    margin-bottom: 10px;
}

.grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
    gap: 10px;
}

.tile {
    background: #222;
    padding: 8px;
    border-radius: 6px;
}

iframe {
    width: 100%;
    height: 240px;
    border: none;
}
</style>
</head>

<body>

<h1>BirdDog Live Grid</h1>

<button onclick="loadStreams()">Refresh</button>

<div class="grid" id="grid"></div>

<script>

async function loadStreams() {

    const grid = document.getElementById("grid");
    grid.innerHTML = "Loading...";

    const host = window.location.hostname;

    try {

        const response = await fetch(`http://${host}:9997/v3/paths/list`);
        const data = await response.json();

        if (!data.items || data.items.length === 0) {
            grid.innerHTML = "No active streams.";
            return;
        }

        grid.innerHTML = "";

        data.items.forEach(item => {

            if (!item.ready) return;

            const tile = document.createElement("div");
            tile.className = "tile";

            const title = document.createElement("div");
            title.innerText = item.name;

            const frame = document.createElement("iframe");
            frame.src = `http://${host}:8889/${item.name}`;

            tile.appendChild(title);
            tile.appendChild(frame);

            grid.appendChild(tile);

        });

    } catch (err) {

        console.error(err);
        grid.innerHTML = "Error loading streams.";

    }

}

loadStreams();

</script>

</body>
</html>
EOF


echo ""
echo "=== Validating nginx config ==="

nginx -t


echo ""
echo "=== Restarting nginx ==="

systemctl restart nginx


echo ""
echo "=== Verification ==="

echo "--- nginx status ---"
systemctl is-active nginx && echo "nginx OK"

echo ""
echo "--- listening port 80 ---"
ss -lntup | grep :80 || true

echo ""
echo "--- web directory ---"
ls -l "$WEB_DIR"

echo ""
echo "================================="
echo "BirdDog Web Dashboard Ready"
echo "================================="
echo ""
echo "Open dashboard at:"
echo "http://$(hostname).local"
echo "or"
echo "http://10.10.10.1"
echo ""
echo "Install log saved to:"
echo "$LOG"
