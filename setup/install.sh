#!/bin/bash
set -e

MODE=$1  # server or camera
BASE_DIR=$(dirname "$(realpath "$0")")

if [[ "$EUID" -ne 0 ]]; then
  echo "YOU FORGOT THE SUDO"
  exit 1
fi

read -rp "Mode? [camera/server]: " MODE
MODE=$(echo "$MODE" | tr '[:upper:]' '[:lower:]')

if [[ "$MODE" != "server" && "$MODE" != "camera" ]]; then
  echo "$MODE is not an option"
  echo "Please try typing better"
  exit 1
fi

read -rp "Enter unit name (camera1/server1): " UNIT_NAME
echo ">>> Setting hostname to '$UNIT_NAME'"
echo "$UNIT_NAME" > /etc/hostname
sed -i "s/127.0.1.1.*/127.0.1.1\t$UNIT_NAME/" /etc/hosts
hostnamectl set-hostname "$UNIT_NAME"

read -rp "Set location: tt (Talking Trees), sm (Sunrise Mountain), eq (Emerald Queen), or none: " LOCATION_SHORT
LOCATION_SHORT=$(echo "$LOCATION_SHORT" | tr '[:upper:]' '[:lower:]')

case "$LOCATION_SHORT" in
  tt)
    LOCATION="talking_trees"
    ;;
  sm)
    LOCATION="sunrise_mountain"
    ;;
  eq)
    LOCATION="emerald_queen"
    ;;
  none)
    LOCATION="none"
    ;;
  *)
    echo "Invalid location code: $LOCATION_SHORT"
    echo "Location code options: [tt/sm/eq/none]"
    exit 1
    ;;
esac

echo ">>> Updating system and installing dependencies"
apt update
apt upgrade -y
apt install -y git python3-pip mosquitto mosquitto-clients avahi-daemon sqlite3

echo ">>> Installing WittyPi"
apt-get -y remove fake-hwclock
update-rc.d -f fake-hwclock remove
systemctl disable fake-hwclock
rm -f /lib/udev/hwclock-set

wget https://www.uugear.com/repo/WittyPi4/install.sh -O /home/pi/wittypi_install.sh
chown pi:pi /home/pi/wittypi_install.sh
bash /home/pi/wittypi_install.sh
rm /home/pi/wittypi_install.sh

echo ">>> Unblocking Wi-Fi"
rfkill unblock wifi || echo "rfkill not available or failed"
raspi-config nonint do_wifi_country US

if [[ "$MODE" == "server" ]]; then
  echo ">>> Configuring as SERVER (Wi-Fi AP + Modem)"
  sed -i 's/console=serial0,[0-9]* //g' /boot/cmdline.txt

  apt install -y hostapd dnsmasq minicom screen python3-serial ppp

  python3 - <<EOF
import serial
import time

try:
    ser = serial.Serial('/dev/serial0', 9600, timeout=2)
    time.sleep(1)
    ser.write(b'AT\r')
    time.sleep(1)
    ser.write(b'AT+CGDCONT=2\r')
    time.sleep(1)
    ser.write(b'AT+CGDCONT=3\r')
    time.sleep(1)
    ser.close()
    print("Modem PDP context cleanup complete.")
except Exception as e:
    print("Warning: modem cleanup failed —", e)
EOF

  systemctl stop hostapd
  systemctl stop dnsmasq

  echo ">>> Copying config files for server..."
  cp "$BASE_DIR/server/config_server.txt" /boot/config.txt
  cp "$BASE_DIR/server/dhcpcd.conf" /etc/dhcpcd.conf
  cp "$BASE_DIR/server/dnsmasq.conf" /etc/dnsmasq.conf
  cp "$BASE_DIR/server/hostapd.conf" /etc/hostapd/hostapd.conf
  cp "$BASE_DIR/server/hostapd" /etc/default/hostapd
  cp "$BASE_DIR/server/sim7080g_peers" /etc/ppp/peers/sim7080g
  cp "$BASE_DIR/server/sim7080g" /etc/chatscripts/sim7080g
  cp "$BASE_DIR/server/resolv.conf" /etc/ppp/resolv.conf
  cp "$BASE_DIR/server/ip-up" /etc/ppp/ip-up
  cp "$BASE_DIR/server/mosquitto.conf" /etc/mosquitto/mosquitto.conf

  chmod +x /etc/ppp/ip-up

  echo ">>> Setting up hostapd and dnsmasq services"
  systemctl unmask hostapd
  systemctl enable hostapd
  systemctl enable dnsmasq
  systemctl restart dhcpcd
  systemctl start hostapd
  systemctl start dnsmasq
  systemctl restart mosquitto

else
  echo ">>> Configuring as CAMERA (node)"
  cp "$BASE_DIR/node/config_camera.txt" /boot/config.txt
  cp "$BASE_DIR/node/wpa_supplicant.conf" /etc/wpa_supplicant/wpa_supplicant.conf

  echo ">>> IT'S THE FBI"
  apt install -y fbi
  apt install -y feh
fi

echo ">>> Enabling I2C kernel modules"
grep -q '^i2c-dev' /etc/modules || echo "i2c-dev" >> /etc/modules
modprobe i2c-dev || echo "Failed to load i2c-dev module"
modprobe i2c-bcm2835 || echo "⚠Failed to load i2c-bcm2835 module"

echo ">>> Installing Python requirements"
pip3 install --upgrade pip
pip3 install -r "$BASE_DIR/requirements.txt"

echo ">>> Installing systemd services"

cp "$BASE_DIR/systemd_services/bee_cam.service" /etc/systemd/system/
cp "$BASE_DIR/systemd_services/datetime_sync.service" /etc/systemd/system/
systemctl enable bee_cam.service
systemctl enable datetime_sync.service

if [[ "$MODE" == "server" ]]; then
  echo ">>> Installing ppp_connect.service"
  cp "$BASE_DIR/systemd_services/ppp_connect.service" /etc/systemd/system/
  systemctl enable ppp_connect.service
fi

if [[ "$MODE" == "camera" ]]; then
  echo ">>> Installing camera_monitor.service"
  cp "$BASE_DIR/systemd_services/camera_monitor.service" /etc/systemd/system/
  systemctl enable camera_monitor.service
fi

CONFIG_TARGET="$(realpath "$BASE_DIR/..")/config.ini"
EXAMPLE_CONFIG="$(realpath "$BASE_DIR/..")/setup/example_config.ini"
if [[ ! -f "$CONFIG_TARGET" && -f "$EXAMPLE_CONFIG" ]]; then
  cp "$EXAMPLE_CONFIG" "$CONFIG_TARGET"
fi
if grep -q "^name *= *" "$CONFIG_TARGET"; then
  sed -i "s/^name *= *.*/name = $UNIT_NAME/" "$CONFIG_TARGET"
else
  sed -i "/^\[general\]/a name = $UNIT_NAME" "$CONFIG_TARGET"
fi

if grep -q "^mode *= *" "$CONFIG_TARGET"; then
  sed -i "s/^mode *= *.*/mode = $MODE/" "$CONFIG_TARGET"
else
  sed -i "/^\[general\]/a mode = $MODE" "$CONFIG_TARGET"
fi
chown pi:pi "$CONFIG_TARGET"

if [[ "$LOCATION" != "none" ]]; then
  echo ">>> Generating sunrise/sunset times for $LOCATION..."
  python3 "$BASE_DIR/generate_sunrise_sunset_times.py" "$LOCATION"
else
  echo ">>> Skipping sunrise/sunset generation (no location selected)."
fi

echo ">>> Done. Please reboot!"
