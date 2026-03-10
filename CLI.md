sudo nano /usr/local/bin/birddog
#!/bin/bash

show_help() {

echo ""
echo "================================="
echo "BirdDog System Command"
echo "================================="
echo ""
echo "birddog install    → run golden installer"
echo "birddog update     → update scripts from GitHub"
echo "birddog status     → show system health"
echo "birddog restart    → restart BirdDog services"
echo "birddog version    → show installed version"
echo "birddog help       → show this menu"
echo ""
echo "================================="
echo ""

}

run_install() {

SCRIPT="/opt/birddog/common/golden_image_creation.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "Installer not found:"
    echo "$SCRIPT"
    exit 1
fi

sudo bash "$SCRIPT"

}

run_update() {

sudo birddog-update

}

run_status() {

if command -v birddog-status >/dev/null 2>&1; then
    birddog-status
else
    echo "Status tool not installed."
fi

}

run_restart() {

echo ""
echo "Restarting BirdDog services..."
echo ""

restart_service () {

SERVICE=$1

if systemctl list-unit-files | grep -q "^$SERVICE"; then
    echo "Restarting $SERVICE"
    sudo systemctl restart $SERVICE
else
    echo "$SERVICE not installed"
fi

}

restart_service birddog-mesh.service
restart_service birddog-stream.service
restart_service mediamtx.service
restart_service hostapd.service
restart_service dnsmasq.service
restart_service nginx.service

echo ""
echo "Restart complete."

}

run_version() {

FILE="/opt/birddog/version/VERSION"

if [ -f "$FILE" ]; then
    echo "BirdDog Version:"
    cat "$FILE"
else
    echo "Version file not found."
fi

}

case "$1" in

install)
run_install
;;

update)
run_update
;;

status)
run_status
;;

restart)
run_restart
;;

version)
run_version
;;

help|"")
show_help
;;

*)
echo "Unknown command"
show_help
;;

esac
sudo chmod +x /usr/local/bin/birddog
