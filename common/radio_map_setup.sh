#!/bin/bash
set -e

echo "================================="
echo "BirdDog Radio Mapping Installer"
echo "================================="

INSTALL_PATH="/usr/local/bin/birddog-radio-map.sh"
SERVICE_PATH="/etc/systemd/system/birddog-radio-map.service"
LOG_DIR="/opt/birddog/radio"
LOG_FILE="$LOG_DIR/radio_map.log"

mkdir -p "$LOG_DIR"

# -------------------------------------------------------
# Write the runtime script that executes at every boot
# -------------------------------------------------------

cat <<'RUNTIME_EOF' > "$INSTALL_PATH"
#!/bin/bash

# BirdDog Radio Map Runtime
# Runs once at boot (before network-pre.target) via systemd.
# Renames wireless interfaces by driver to deterministic names:
#   wlan1 = Comfast mt76x2u    (mesh backbone, all nodes)
#   wlan2 = Edimax rtl8192cu   (AP + DHCP, BDM only)
#   wlan0 = onboard brcmfmac   (blocked — not used)

LOG="/opt/birddog/radio/radio_map.log"
exec >> "$LOG" 2>&1

echo ""
echo "================================="
echo "Radio Map Runtime $(date)"
echo "================================="

# Give USB adapters a moment to enumerate after kernel init
sleep 4

# -------------------------------------------------------
# Driver → target interface name map
# -------------------------------------------------------
# brcmfmac  = onboard BCM WiFi on Pi 3B         → wlan0 (then blocked)
# mt76x2u   = Comfast CF-WU782AC (mesh)         → wlan1
# rtl8192cu = Edimax EW-7811Un (AP, BDM only)   → wlan2

declare -A DRIVER_TARGET=(
    [brcmfmac]="wlan0"
    [mt76x2u]="wlan1"
    [rtl8192cu]="wlan2"
)

# -------------------------------------------------------
# Discover current interfaces and their drivers
# -------------------------------------------------------

declare -A RENAME_MAP   # current_name → target_name

INTERFACES=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')

if [[ -z "$INTERFACES" ]]; then
    echo "ERROR: No wireless interfaces detected"
    exit 1
fi

echo "Detected interfaces:"

for IF in $INTERFACES; do
    DRIVER=$(ethtool -i "$IF" 2>/dev/null | awk '/driver:/{print $2}')
    TARGET="${DRIVER_TARGET[$DRIVER]:-}"

    echo "  $IF  driver=$DRIVER  target=${TARGET:-UNKNOWN}"

    if [[ -z "$TARGET" ]]; then
        echo "  WARNING: Unrecognised driver '$DRIVER' on $IF — skipping"
        continue
    fi

    RENAME_MAP[$IF]="$TARGET"
done

# -------------------------------------------------------
# Rename — two-pass to avoid collision
# (e.g. wlan0 → wlan1 would collide if wlan1 already exists)
# -------------------------------------------------------

echo ""
echo "Applying renames..."

# Pass 1: rename everything to a temp name
for IF in "${!RENAME_MAP[@]}"; do
    ip link set "$IF" down 2>/dev/null || true
    ip link set "$IF" name "tmp_bd_$IF" 2>/dev/null || true
done

# Pass 2: rename from temp to final target
for IF in "${!RENAME_MAP[@]}"; do
    TARGET="${RENAME_MAP[$IF]}"
    ip link set "tmp_bd_$IF" name "$TARGET" 2>/dev/null || true
    echo "  tmp_bd_$IF → $TARGET"
done

# -------------------------------------------------------
# Block onboard radio — reduce RF congestion
# -------------------------------------------------------

echo ""
echo "Blocking onboard radio (wlan0 / brcmfmac)..."

if ip link show wlan0 >/dev/null 2>&1; then
    ip link set wlan0 down || true
    # rfkill soft-block by interface index if available
    IDX=$(cat /sys/class/net/wlan0/ifindex 2>/dev/null || true)
    if [[ -n "$IDX" ]]; then
        rfkill block "$IDX" 2>/dev/null || true
    fi
    # Also attempt block-all-wifi then unblock USB adapters
    rfkill block wifi 2>/dev/null || true
    sleep 1
    for IF in wlan1 wlan2; do
        if ip link show "$IF" >/dev/null 2>&1; then
            rfkill unblock wifi 2>/dev/null || true
            break
        fi
    done
    echo "  wlan0 blocked"
else
    echo "  wlan0 not present — nothing to block"
fi

# -------------------------------------------------------
# Bring up USB radios in managed mode (clean baseline)
# -------------------------------------------------------

for IF in wlan1 wlan2; do
    if ip link show "$IF" >/dev/null 2>&1; then
        iw dev "$IF" set type managed 2>/dev/null || true
        ip link set "$IF" up 2>/dev/null || true
        echo "  $IF up (managed)"
    fi
done

# -------------------------------------------------------
# Final layout summary
# -------------------------------------------------------

echo ""
echo "Final radio layout:"

for IF in wlan0 wlan1 wlan2; do
    if ip link show "$IF" >/dev/null 2>&1; then
        DRIVER=$(ethtool -i "$IF" 2>/dev/null | awk '/driver:/{print $2}')
        STATE=$(ip link show "$IF" | awk '/state/{print $9}')
        echo "  $IF  driver=$DRIVER  state=$STATE"
    else
        echo "  $IF  not present"
    fi
done

# -------------------------------------------------------
# Verify expected mesh adapter is present
# -------------------------------------------------------

if ! ip link show wlan1 >/dev/null 2>&1; then
    echo ""
    echo "ERROR: wlan1 (mesh adapter / mt76x2u) not present after mapping"
    echo "       Check that Comfast adapter is plugged in"
    exit 1
fi

echo ""
echo "Radio mapping complete."
RUNTIME_EOF

chmod +x "$INSTALL_PATH"

# -------------------------------------------------------
# Install systemd service
# -------------------------------------------------------

cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=BirdDog Radio Mapping
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable birddog-radio-map.service

echo ""
echo "================================="
echo "Radio mapping service installed"
echo ""
echo "Layout at next boot:"
echo "  wlan0 = onboard brcmfmac  (blocked)"
echo "  wlan1 = Comfast mt76x2u   (mesh)"
echo "  wlan2 = Edimax rtl8192cu  (AP, BDM only)"
echo ""
echo "Log: $LOG_FILE"
echo "================================="
