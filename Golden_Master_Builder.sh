echo "Removing old golden_image_creation.sh if present..."
rm -f golden_image_creation.sh
echo "Done."

echo "Starting download of latest golden_image_creation.sh..."
if curl -fL "https://raw.githubusercontent.com/badandyc/BirdDog/main/golden_image_creation.sh?$(date +%s)" -o golden_image_creation.sh; then
    echo "Download complete."
else
    echo "Download failed."
    exit 1
fi

echo "Setting executable permissions..."
chmod +x golden_image_creation.sh
echo "Done."

echo "Running golden image creation script..."
sudo ./golden_image_creation.sh
echo "Golden image creation complete."
