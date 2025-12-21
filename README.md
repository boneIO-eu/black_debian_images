# black_debian_images

Instruction to create same image.

## USB Mode

```
sudo cp /etc/bbb.io/templates/usb0-DHCP.network /etc/systemd/network/usb0.network
```

## sysconf.txt

```
user_name=boneio
user_password=Black
hostname=boneIOBlack
timezone=Europe/Warsaw
usb_enable_dhcp=yes
enable_ufw=yes
ufw_allow_ssh=yes
```

## UFW Section
```bash
sudo ufw allow 1883
sudo ufw allow 8090
sudo ufw allow 8091
```

## APT Install section

```
sudo apt update
sudo apt install -y libopenjp2-7-dev python3-venv libjpeg-dev docker-compose docker.io fonts-dejavu-core fonts-dejavu-extra libffi-dev libfreetype-dev libtiff6 libxcb1 mosquitto
usermod -aG docker boneio
exit # and relogin
```

## GPIO Preparation (for each Kernel!)

```bash
cd /opt/source
git clone https://github.com/boneIO-eu/black-pins-overlay.git
cd black-pins-overlay/
chmod +x build_boneio_black_pins.sh Makefile
./build_boneio_black_pins.sh
```

```
sudo sed -i \
    -e 's/#enable_uboot_overlays=1/enable_uboot_overlays=1\nuboot_overlay_addr0=BONEIO-BLACK-PINS.dtbo/' \
    -e 's/#disable_uboot_overlay_video=1/disable_uboot_overlay_video=1/' \
    -e 's/#disable_uboot_overlay_audio=1/disable_uboot_overlay_audio=1/' \
    -e 's/#disable_uboot_overlay_wireless=1/disable_uboot_overlay_wireless=1/' \
    -e 's/^uboot_overlay_pru=/#uboot_overlay_pru=/' \
    /boot/uEnv.txt
```

## APT Remove Section

```bash
sudo apt remove manpages wireless-tools ti-pru-cgt-v2.3 alsa-topology-conf alsa-ucm-conf bb-u-boot-am57xx-evm bb-wl18xx-firmware bb-wlan0-defaults bluetooth bluez firmware-atheros firmware-brcm80211 firmware-libertas firmware-mediatek firmware-realtek hostapd ncal nginx nginx-common rfkill wireguard-tools
```

## Clean runtime

```
sudo systemctl disable --now apt-daily-upgrade.timer
sudo systemctl disable unattended-upgrades.service
sudo systemctl disable --now apt-daily.timer
```

## Docker section

```
mkdir -p ~/docker/nodered/data
mkdir ~/docker/nodered/node-red
mkdir ~/docker/nodered/nginx
mkdir -p /home/boneio/docker/nodered && \
tee ~/docker/nodered/docker-compose.yaml <<'EOF'
services:
  node-red:
    image: nodered/node-red:4.1.2-22
    restart: unless-stopped
    environment:
      TZ: Europe/Warsaw
    volumes:
      - ./data:/data
      - ./node-red/settings.js:/data/settings.js:ro
    networks:
      - edge

  nginx:
    image: nginx:1.29-alpine
    restart: unless-stopped
    depends_on:
      - node-red
    ports:
      - "${NGINX_PORT:-8091}:80"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - edge

networks:
  edge:
EOF
cd ~/docker/nodered/
docker-compose up
```

### Journalctl settings

/etc/systemd/journald.conf
```
[Journal]
Compress=yes
SystemMaxUse=300M
SystemKeepFree=300M
SystemMaxFileSize=50M
MaxRetentionSec=2weeks
```
SystemMaxFileSize=50M
MaxRetentionSec=2weeks
```

### MOSQUITTO

```
sudo tee /etc/mosquitto/conf.d/boneio.conf <<EOF
listener 1883
password_file /etc/mosquitto/passwd
EOF

sudo chown mosquitto:mosquitto /etc/mosquitto/passwd /etc/mosquitto/conf.d/boneio.conf
sudo mosquitto_passwd -c -b /etc/mosquitto/passwd boneio boneio123
```
