Converting this repository for all scripts to be included in golden master img

Build Golden Master Image \
rm -f golden_image_creation.sh && \
curl -fsSL "https://raw.githubusercontent.com/badandyc/BirdDog/main/golden_image_creation.sh?$(date +%s)" -o golden_image_creation.sh && \
sudo bash golden_image_creation.sh

MISC: \
ping <bdm-hostname>.local \
systemctl status birddog-stream \
http://10.10.10.1:8889/cam01 \
ssh-keygen -R x.x.x.x \
