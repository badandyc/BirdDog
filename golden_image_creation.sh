sudo apt update && sudo apt install -y ffmpeg rpicam-apps avahi-daemon nginx hostapd dnsmasq
sudo mkdir -p /opt/birddog
sudo chmod -R 777 /opt/birddog
sudo mkdir -p /opt/birddog/bdm
sudo mkdir -p /opt/birddog/bdc
sudo mkdir -p /opt/birddog/mediamtx
sudo mkdir -p /opt/birddog/web
cd /opt/birddog
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_initial_setup.sh -o bdm/bdm_initial_setup.sh
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_AP_setup.sh -o bdm/bdm_AP_setup.sh
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_mediamtx_setup.sh -o bdm/bdm_mediamtx_setup.sh
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/bdm/bdm_web_setup.sh -o bdm/bdm_web_setup.sh
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/bdc/bdc_fresh_install_setup.sh -o bdc/bdc_fresh_install_setup.sh
curl -fsSL https://raw.githubusercontent.com/badandyc/BirdDog/main/start.sh -o start.sh
sudo chmod +x /opt/birddog/start.sh
sudo chmod +x /opt/birddog/bdm/*.sh
sudo chmod +x /opt/birddog/bdc/*.sh
