#!/bin/bash
set -e

LOG="/opt/birddog/radio/radio_map.log"
exec > >(tee -a "$LOG") 2>&1

echo "================================="
echo "BirdDog Radio Mapping Setup"
date
echo "================================="

echo "Waiting for wireless interfaces..."
sleep 5

INTERFACES=$(iw dev | awk '$1=="Interface"{print $2}')

if [[ -z "$INTERFACES" ]]; then
    echo "ERROR: No wireless interfaces detected."
    exit 1
fi

echo ""
echo "Detected wireless interfaces:"
echo "$INTERFACES"
echo ""

for IF in $INTERFACES
do

    DRIVER=$(ethtool -i $IF 2>/dev/null | grep driver | awk '{print $2}')

    echo "Interface: $IF"
    echo "Driver: $DRIVER"

    if [[ "$DRIVER" == "brcmfmac" ]]; then
        TARGET="wlan0"

    elif [[ "$DRIVER" == "mt76x2u" ]]; then
        TARGET="wlan1"

    else
        TARGET="wlan2"
    fi

    echo "Mapping → $TARGET"

    if [[ "$IF" != "$TARGET" ]]; then
        ip link set $IF down
        ip link set $IF name $TARGET
    fi

    echo ""

done

echo "================================="
echo "Final Radio Layout"
echo "================================="

for IF in wlan0 wlan1 wlan2
do
    if ip link show $IF >/dev/null 2>&1; then
        DRIVER=$(ethtool -i $IF 2>/dev/null | grep driver | awk '{print $2}')
        echo "$IF  →  $DRIVER"
    fi
done

echo ""
echo "Radio mapping complete."
echo "Log saved to:"
echo "$LOG"
