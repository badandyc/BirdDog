#!/bin/bash
set -e

echo "Installing BirdDog bootstrap CLI..."

cat << 'EOF' > /usr/local/bin/bootstrap
#!/bin/bash
set -e

echo ""
echo "====================================="
echo "BirdDog Bootstrap"
echo "====================================="
echo ""

echo "[1/4] Network check..."

if ! ping -c1 github.com >/dev/null 2>&1; then
    echo "ERROR: Cannot reach github.com"
    exit 1
fi

echo "Network OK"


echo "[2/4] TLS check..."

if ! curl -Is https://raw.githubusercontent.com >/dev/null 2>&1; then
    echo "ERROR: TLS validation failed"
    exit 1
fi

echo "TLS OK"


echo "[3/4] Determining latest commit..."

TARGET_COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)

echo "Latest BirdDog commit: $TARGET_COMMIT"


echo "[4/4] Downloading golden installer..."

TMP_GOLDEN="/tmp/birddog_golden.$$"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/golden_image_creation.sh?$(date +%s)" \
-o "$TMP_GOLDEN"

chmod +x "$TMP_GOLDEN"

echo ""
echo "Golden installer ready."
echo ""
echo "Run it with:"
echo ""
echo "    sudo $TMP_GOLDEN"
echo ""
echo "Or move it somewhere permanent."
echo ""
EOF

chmod +x /usr/local/bin/bootstrap

echo ""
echo "====================================="
echo "Bootstrap CLI Installed"
echo "====================================="
echo ""
echo "Next step:"
echo ""
echo "    bootstrap"
echo ""
