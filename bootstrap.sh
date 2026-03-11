#!/bin/bash
set -e

echo ""
echo "====================================="
echo "BirdDog Bootstrap Installer"
echo "====================================="
echo ""

echo "[1/6] Network reachability check..."

if ! ping -c1 github.com >/dev/null 2>&1; then
    echo "ERROR: Cannot reach github.com"
    exit 1
fi

echo "Network OK"


echo "[2/6] TLS validation check..."

if ! curl -Is https://raw.githubusercontent.com >/dev/null 2>&1; then
    echo "ERROR: TLS validation failed"
    exit 1
fi

echo "TLS OK"


echo "[3/6] Determining target commit..."

TARGET_COMMIT=$(git ls-remote https://github.com/badandyc/BirdDog HEAD | cut -c1-7)

echo "Target commit: $TARGET_COMMIT"


echo "[4/6] Fetching golden installer..."

TMP_GOLDEN="/tmp/birddog_golden.$$"

curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/common/golden_image_creation.sh?$(date +%s)" \
-o "$TMP_GOLDEN"

chmod +x "$TMP_GOLDEN"

echo "Golden installer downloaded."


echo "[5/6] Executing golden installer..."

sudo "$TMP_GOLDEN"

rm -f "$TMP_GOLDEN"


echo "[6/6] Final commit verification..."

if [[ -f /opt/birddog/version/COMMIT ]]; then
    FINAL_COMMIT=$(cat /opt/birddog/version/COMMIT)
    echo "Installed commit: $FINAL_COMMIT"
else
    echo "WARNING: Commit file not found."
fi

echo ""
echo "====================================="
echo "BirdDog Bootstrap Complete"
echo "====================================="
echo ""
echo "Next step:"
echo ""
echo "    birddog install"
echo ""
