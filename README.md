rm -f ~/golden_image_creation.sh && \
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/common/golden_image_creation.sh?$(date +%s) -o ~/golden_image_creation.sh && \
chmod +x ~/golden_image_creation.sh && \
sudo ~/golden_image_creation.sh && \
rm -f ~/golden_image_creation.sh

birddog \
mesh \

MISC: \
ping <bdm-hostname>.local \
systemctl status birddog-stream \
http://10.10.10.1:8889/cam01 \
ssh-keygen -R x.x.x.x \
rpicam-vid -t 5000 -o test.h264 \
mesh status
