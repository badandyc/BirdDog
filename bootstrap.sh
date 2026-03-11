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

echo "[1/5] Network check..."

if ! ping -c1 github.com >/dev/null 2>&1; then
    echo "ERROR: Cannot reach github.com"
    exit 1
fi

echo "Network OK"


echo "[2/5] TLS validation..."

if ! curl -Is https://raw.githubusercontent.com >/dev/null 2>&1; then
    echo "ERROR: TLS validation failed"
    exit 1
fi

echo "TLS OK"


echo "[3/5] Determining latest commit..."

TARGET_COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)

echo "Latest BirdDog commit: $TARGET_COMMIT"


echo "[4/5] Fetching golden installer..."

TMP_GOLDEN="/tmp/birddog_golden.$$"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/golden_image_creation.sh?$(date +%s)" \
-o "$TMP_GOLDEN"

chmod +x "$TMP_GOLDEN"

echo "Running golden installer..."

sudo "$TMP_GOLDEN"

rm -f "$TMP_GOLDEN"


echo "[5/5] Cleaning bootstrap tool..."

rm -f /usr/local/bin/bootstrap

echo ""
echo "Bootstrap complete."
echo ""
echo "BirdDog CLI is now available:"
echo ""
echo "    birddog"
echo ""
echo "Next step:"
echo ""
echo "    birddog xxx"
echo ""
EOF

chmod +x /usr/local/bin/bootstrap

echo ""
echo "====================================="
echo "Bootstrap CLI Installed"
echo "====================================="
echo ""
echo "Run:"
echo ""
echo "    bootstrap"
echo ""
