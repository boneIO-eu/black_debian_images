#!/bin/bash
## BoneIO Black - Complete System Setup Script
## Usage: curl -H 'Cache-Control: no-cache' -fsSL https://raw.githubusercontent.com/boneIO-eu/black_debian_images/main/scripts/setup_boneio.sh | sudo bash
## Options: --no-cleanup  Skip final cleanup step (for testing on a live system)
##
## This script configures a fresh Debian 13 installation for BoneIO Black hardware.
## It will install all required packages, configure services, and prepare the system
## for image creation.

set -e

# Parse arguments
NO_CLEANUP=false
for arg in "$@"; do
    case "$arg" in
        --no-cleanup) NO_CLEANUP=true ;;
    esac
done

# Check root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with sudo privileges!"
   echo "Usage: curl -fsSL ... | sudo bash"
   exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

BONEIO_USER="${BONEIO_USER:-boneio}"
BONEIO_HOME="/home/${BONEIO_USER}"
SCRIPT_VERSION="2026-04-11.1"

echo "================================================================================"
echo "  BoneIO Black - System Setup"
echo "  Version: ${SCRIPT_VERSION}"
echo "================================================================================"
echo "User: ${BONEIO_USER}"
echo "Home: ${BONEIO_HOME}"
if $NO_CLEANUP; then
    echo "Mode: NO CLEANUP (live testing)"
fi
echo ""

# =============================================================================
# STEP 1: UFW Firewall
# =============================================================================
log_info "1/11: Configuring UFW firewall..."
ufw allow 1883  # MQTT
ufw allow 8090  # BoneIO Web
ufw allow 8091  # Nginx proxy
ufw logging off
log_info "   UFW configured"

# =============================================================================
# STEP 2: APT Install
# =============================================================================
log_info "2/11: Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt update
apt install -y \
    libopenjp2-7-dev \
    python3-venv \
    libjpeg-dev \
    docker-compose \
    docker.io \
    fonts-dejavu-core \
    fonts-dejavu-extra \
    libffi-dev \
    libfreetype-dev \
    libtiff6 \
    libxcb1 \
    mosquitto \
    log2ram \
    git \
    make \
    device-tree-compiler

usermod -aG docker ${BONEIO_USER}
log_info "   Packages installed"

# =============================================================================
# STEP 3: APT Remove unnecessary packages
# =============================================================================
log_info "3/11: Removing unnecessary packages..."
apt remove -y \
    manpages \
    wireless-tools \
    ti-pru-cgt-v2.3 \
    alsa-topology-conf \
    alsa-ucm-conf \
    bb-u-boot-am57xx-evm \
    bb-wl18xx-firmware \
    bb-wlan0-defaults \
    bluetooth \
    bluez \
    firmware-atheros \
    firmware-brcm80211 \
    firmware-libertas \
    firmware-mediatek \
    firmware-realtek \
    hostapd \
    ncal \
    nginx \
    nginx-common \
    rfkill \
    wireguard-tools \
    firmware-ti-connectivity \
    wget 2>/dev/null || true
apt autoremove -y
apt-get clean
log_info "   Unnecessary packages removed"

# =============================================================================
# STEP 4: Disable unnecessary timers
# =============================================================================
log_info "4/11: Disabling unnecessary services..."
systemctl disable --now apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable unattended-upgrades.service 2>/dev/null || true
systemctl disable --now apt-daily.timer 2>/dev/null || true
log_info "   Services disabled"

# =============================================================================
# STEP 5: Docker + Node-RED + Nginx setup (directories only)
# =============================================================================
log_info "5/11: Setting up Docker directories..."

mkdir -p ${BONEIO_HOME}/docker/nodered/node-red/data
mkdir -p ${BONEIO_HOME}/docker/nodered/nginx
chown -R ${BONEIO_USER}:${BONEIO_USER} ${BONEIO_HOME}/docker
log_info "   Docker directories created"

# PLACEHOLDER: Docker + Nginx + journald + mosquitto + sudoers + OLED + systemd
# files are now managed by boneio-migrate (called in STEP 9 below).

# Docker logging limits — applied by migration; restart docker now
cat > ${BONEIO_HOME}/docker/nodered/docker-compose.yaml << 'EOF'
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

cat > ${BONEIO_HOME}/docker/nodered/node-red/settings.js << 'EOF'
module.exports = {
  httpAdminRoot: "/nodered",
  httpNodeRoot: "/nodered",
  ui: { path: "ui" },
};
EOF

cat > ${BONEIO_HOME}/docker/nodered/nginx/default.conf << 'EOF'
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

    error_page 502 503 504 /502.html;
    location = /502.html {
        root /usr/share/nginx/html;
        internal;
    }

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

chown -R ${BONEIO_USER}:${BONEIO_USER} ${BONEIO_HOME}/docker
log_info "   Docker environment configured"

# Docker logging limits
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
systemctl restart docker

# =============================================================================
# STEP 6: Mosquitto — bootstrap passwd file (data only, not config)
# =============================================================================
log_info "6/11: Bootstrapping Mosquitto passwd file..."

systemctl stop mosquitto 2>/dev/null || true
rm -f /var/lib/mosquitto/mosquitto.db /var/lib/mosquitto/*.db
touch /etc/mosquitto/passwd
chmod 0600 /etc/mosquitto/passwd
chown mosquitto:mosquitto /etc/mosquitto/passwd
mosquitto_passwd -b /etc/mosquitto/passwd boneio boneio123
mosquitto_passwd -b /etc/mosquitto/passwd homeassistant boneio123
mosquitto_passwd -b /etc/mosquitto/passwd mqtt boneio123
log_info "   Mosquitto passwd bootstrapped (config applied by migration)"

# Steps 7-8 (journald, sudoers, OLED, systemd services) are applied below
# by boneio-migrate after pip install. No heredocs needed here.

# =============================================================================
# STEP 8: Early OLED boot splash (initramfs)
# =============================================================================
log_info "8/11: Installing early OLED boot splash (initramfs)..."
INITRAMFS_HOOK_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/initramfs/hooks/oled-splash"
INITRAMFS_SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/initramfs/scripts/init-premount/oled-splash"

if [ -f "${INITRAMFS_HOOK_SRC}" ] && [ -f "${INITRAMFS_SCRIPT_SRC}" ]; then
    cp "${INITRAMFS_HOOK_SRC}" /etc/initramfs-tools/hooks/oled-splash
    chmod +x /etc/initramfs-tools/hooks/oled-splash

    mkdir -p /etc/initramfs-tools/scripts/init-premount
    cp "${INITRAMFS_SCRIPT_SRC}" /etc/initramfs-tools/scripts/init-premount/oled-splash
    chmod +x /etc/initramfs-tools/scripts/init-premount/oled-splash

    update-initramfs -u
    log_info "   Early OLED splash installed (initramfs rebuilt)"
else
    log_warn "Initramfs OLED splash sources not found, skipping"
fi

# =============================================================================
# STEP 9: BoneIO application installation
# =============================================================================
log_info "9/11: Installing BoneIO application..."
mkdir -p ${BONEIO_HOME}/boneio
python3 -m venv ${BONEIO_HOME}/boneio/venv
${BONEIO_HOME}/boneio/venv/bin/pip install --upgrade pip
${BONEIO_HOME}/boneio/venv/bin/pip install --upgrade boneio

# Copy example configs
BONEIO_PKG_PATH=$(${BONEIO_HOME}/boneio/venv/bin/python -c "import boneio; print(boneio.__path__[0])")
if [ -d "${BONEIO_PKG_PATH}/example_config" ]; then
    cp -r ${BONEIO_PKG_PATH}/example_config/* ${BONEIO_HOME}/boneio/ 2>/dev/null || true
fi

chown -R ${BONEIO_USER}:${BONEIO_USER} ${BONEIO_HOME}/boneio

# Install and run boneio-migrate bootstrap
# This installs the helper to /usr/sbin/boneio-migrate with NOPASSWD sudoers,
# then applies all pending system migrations (journald, mosquitto conf,
# sudoers, OLED scripts, systemd services, docker daemon.json, etc.).
log_info "   Running boneio-migrate bootstrap..."
BONEIO_MIGRATE_HELPER="${BONEIO_HOME}/boneio/venv/lib/python*/site-packages/boneio/migrations/bootstrap/boneio-migrate"
BONEIO_MIGRATE_SUDOERS="${BONEIO_HOME}/boneio/venv/lib/python*/site-packages/boneio/migrations/bootstrap/sudoers-migrate"
BONEIO_INSTALL_HELPER="${BONEIO_HOME}/boneio/venv/lib/python*/site-packages/boneio/migrations/bootstrap/install-helper.sh"

# Resolve globs
for F in $BONEIO_MIGRATE_HELPER; do BONEIO_MIGRATE_HELPER="$F"; break; done
for F in $BONEIO_MIGRATE_SUDOERS; do BONEIO_MIGRATE_SUDOERS="$F"; break; done
for F in $BONEIO_INSTALL_HELPER; do BONEIO_INSTALL_HELPER="$F"; break; done

if [ -f "${BONEIO_INSTALL_HELPER}" ]; then
    bash "${BONEIO_INSTALL_HELPER}" "${BONEIO_MIGRATE_HELPER}" "${BONEIO_MIGRATE_SUDOERS}"
    # Apply all migrations via MigrationRunner (boneio-migrate helper expects JSON on stdin,
    # not CLI args — the runner generates the JSON plan and pipes it to the helper).
    sudo -u ${BONEIO_USER} ${BONEIO_HOME}/boneio/venv/bin/python3 -c "
from boneio.migrations.runner import MigrationRunner
r = MigrationRunner()
r.apply_all()
" || true
else
    log_warn "boneio-migrate bootstrap not found, skipping migration apply"
fi

log_info "   BoneIO application installed"

# =============================================================================
# STEP 10: Device Tree Overlay
# =============================================================================
log_info "10/11: Building and installing Device Tree Overlay..."
cd /opt/source
if [ -d "black-pins-overlay" ]; then
    log_info "   Updating existing overlay repo..."
    cd black-pins-overlay
    git stash 2>/dev/null || true
    git pull --ff-only origin main || git pull --ff-only origin master || true
else
    log_info "   Cloning overlay repo..."
    git clone https://github.com/boneIO-eu/black-pins-overlay.git
    cd black-pins-overlay
fi
chmod +x build_boneio_black_pins.sh Makefile
./build_boneio_black_pins.sh

# Configure uEnv.txt
sed -i \
    -e 's/#enable_uboot_overlays=1/enable_uboot_overlays=1\nuboot_overlay_addr0=BONEIO-BLACK-PINS.dtbo/' \
    -e 's/#disable_uboot_overlay_video=1/disable_uboot_overlay_video=1/' \
    -e 's/#disable_uboot_overlay_audio=1/disable_uboot_overlay_audio=1/' \
    -e 's/#disable_uboot_overlay_wireless=1/disable_uboot_overlay_wireless=1/' \
    -e 's/^uboot_overlay_pru=/#uboot_overlay_pru=/' \
    /boot/uEnv.txt

log_info "   Device Tree Overlay installed"

# =============================================================================
# STEP 11: Final cleanup (prepare_image.sh functionality)
# =============================================================================
if $NO_CLEANUP; then
    log_warn "Skipping cleanup (--no-cleanup). System is ready for live testing."
    log_info "OLED boot splash service is enabled. Reboot to test it."
    log_info "To test OLED manually: /usr/sbin/oled_msg.sh 'Test line 1' 'Test line 2'"
    echo ""
    echo "================================================================================"
    echo "  SETUP COMPLETE (no cleanup, no shutdown)"
    echo "================================================================================"
    exit 0
fi

log_info "11/11: Running final cleanup..."

# UTF-8 locale
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# set-hostname-once.sh + set-hostname-once.service are managed by
# boneio-migrate (applied in STEP 9 above). No heredoc needed here.

# Clean up
apt-get autoremove -y
apt-get clean
journalctl --vacuum-time=0d
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -rf /var/lib/dhcp/*
rm -rf /var/lib/NetworkManager/*.lease
rm -f /etc/ssh/ssh_host_*
touch /etc/bbb.io/ssh_regenerate
find /var/log -type f -exec truncate -s 0 {} \;
rm -rf /tmp/*
rm -rf /var/tmp/*

# Clear bash history
history -c
rm -f /root/.bash_history
rm -f ${BONEIO_HOME}/.bash_history

echo ""
echo "================================================================================"
echo "  SETUP COMPLETE!"
echo "================================================================================"
echo ""
echo "System will shutdown in 5 seconds."
echo "After shutdown:"
echo "  1. Remove SD card from BBB"
echo "  2. On PC: sudo ./create_rootfs_img.sh /dev/sdX rootfs.img"
echo ""

sleep 5
poweroff
