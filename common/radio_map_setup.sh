#!/bin/bash
set -e

mkdir -p /opt/birddog/radio

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

declare -A TARGET_MAP

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

    echo "Mapping target → $TARGET"

    TARGET_MAP[$IF]=$TARGET

    echo ""

done


echo "================================="
echo "Applying interface mapping"
echo "================================="

# Step 1: rename everything to temp names to avoid collisions
for IF in "${!TARGET_MAP[@]}"
do
    ip link set $IF down
    ip link set $IF name temp_$IF
done

# Step 2: rename temp names to targets
for IF in "${!TARGET_MAP[@]}"
do
    TARGET=${TARGET_MAP[$IF]}
    ip link set temp_$IF name $TARGET
done


echo ""
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
