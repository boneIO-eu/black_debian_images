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
sudo apt remove manpages wireless-tools ti-pru-cgt-v2.3 alsa-topology-conf alsa-ucm-conf bb-u-boot-am57xx-evm bb-wl18xx-firmware bb-wlan0-defaults bluetooth bluez firmware-atheros firmware-brcm80211 firmware-libertas firmware-mediatek firmware-realtek hostapd ncal nginx nginx-common rfkill wireguard-tools firmware-ti-connectivity wget
sudo apt autoremove
```

## Clean runtime

```
sudo systemctl disable --now apt-daily-upgrade.timer
sudo systemctl disable unattended-upgrades.service
sudo systemctl disable --now apt-daily.timer
```

## Docker section

```
mkdir -p ~/docker/nodered/node-red/data
mkdir ~/docker/nodered/nginx
tee ~/docker/nodered/docker-compose.yaml <<'EOF'
services:
  node-red:
    image: nodered/node-red:4.1.2-22-minimal
    restart: unless-stopped
    environment:
      TZ: Europe/Warsaw
    volumes:
      - ./node-red/data:/data
      - ./node-red/settings.js:/data/settings.js:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - edge

  nginx:
    image: nginx:1.29-alpine-slim
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
tee ~/docker/nodered/node-red/settings.js <<EOF
module.exports = {
  httpAdminRoot: "/nodered",
  httpNodeRoot: "/nodered",
  ui: { path: "ui" },
};
EOF
tee /home/boneio/docker/nodered/nginx/default.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

upstream boneio {
    server host.docker.internal:8090;
}

upstream nodered {
    server node-red:1880;
}

server {
    listen 80;

    # Endpoint for frontend to check if Node-RED is available
    location = /nodered-status {
        default_type application/json;
        add_header X-NodeRed-Available "true" always;
        add_header Access-Control-Expose-Headers "X-NodeRed-Available" always;
        return 200 '{"available": true}';
    }

    location /nodered/ {
        proxy_pass http://nodered;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        add_header X-NodeRed-Available "true" always;
    }

    location / {
        proxy_pass http://boneio;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
EOF

echo '{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
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

### MOSQUITTO

```
sudo tee /etc/mosquitto/conf.d/boneio.conf <<EOF
listener 1883
password_file /etc/mosquitto/passwd
EOF

sudo mosquitto_passwd -c -b /etc/mosquitto/passwd boneio boneio123
sudo mosquitto_passwd -b /etc/mosquitto/passwd homeassistant boneio123
sudo mosquitto_passwd -b /etc/mosquitto/passwd mqtt boneio123
sudo tee /etc/sudoers.d/boneio <<'EOF'
# Allow mosquitto_passwd command for password file
boneio ALL=(ALL) NOPASSWD: /usr/bin/mosquitto_passwd -c -b /etc/mosquitto/passwd boneio boneio123
boneio ALL=(ALL) NOPASSWD: /usr/bin/mosquitto_passwd -b /etc/mosquitto/passwd homeassistant boneio123
boneio ALL=(ALL) NOPASSWD: /usr/bin/mosquitto_passwd -b /etc/mosquitto/passwd mqtt boneio123

# Allow mosquitto service reload
boneio ALL=(ALL) NOPASSWD: /bin/systemctl reload mosquitto
EOF
sudo chmod 0440 /etc/sudoers.d/boneio
sudo chmod 0700 /etc/mosquitto/passwd /etc/mosquitto/conf.d/boneio.conf
```
