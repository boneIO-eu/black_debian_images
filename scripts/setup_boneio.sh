#!/bin/bash
## BoneIO Black - Complete System Setup Script
## Usage: curl -H 'Cache-Control: no-cache' -fsSL https://raw.githubusercontent.com/boneIO-eu/black_debian_images/main/scripts/setup_boneio.sh | sudo bash
## Options: --no-cleanup  Skip final cleanup step (for testing on a live system)
##          --force       Force re-run all steps (ignore completion markers)
##
## This script configures a fresh Debian 13 installation for BoneIO Black hardware.
## It will install all required packages, configure services, and prepare the system
## for image creation.
##
## Idempotent: completed steps are marked and skipped on re-run (like Ansible).

set -e

# Parse arguments
NO_CLEANUP=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --no-cleanup) NO_CLEANUP=true ;;
        --force)      FORCE=true ;;
    esac
done

# Check root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with sudo privileges!"
   echo "Usage: curl -fsSL ... | sudo bash"
   exit 1
fi

# Colors
BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_skip() { echo -e "${BLUE}[SKIP]${NC} $1"; }

BONEIO_USER="${BONEIO_USER:-boneio}"
BONEIO_HOME="/home/${BONEIO_USER}"
SCRIPT_VERSION="2026-07-28.1"

# --- Idempotent step markers ---
MARKER_DIR="/var/lib/boneio/.setup.d"
mkdir -p "${MARKER_DIR}"

# Check if a step was already completed within the last 24h.
# Returns 0 (true) if should skip, 1 (false) if should run.
step_done() {
    if $FORCE; then return 1; fi
    local marker="${MARKER_DIR}/$1.done"
    if [ ! -f "$marker" ]; then return 1; fi
    # Check if marker is younger than 24h (86400 seconds)
    local age=$(( $(date +%s) - $(stat -c %Y "$marker") ))
    [ "$age" -lt 86400 ]
}

# Mark a step as completed (touch updates mtime).
step_mark() {
    touch "${MARKER_DIR}/$1.done"
}

# Reset all markers
if $FORCE; then
    rm -f "${MARKER_DIR}"/*.done
fi

echo "================================================================================"
echo "  BoneIO Black - System Setup"
echo "  Version: ${SCRIPT_VERSION}"
echo "================================================================================"
echo "User: ${BONEIO_USER}"
echo "Home: ${BONEIO_HOME}"
if $NO_CLEANUP; then
    echo "Mode: NO CLEANUP (live testing)"
fi
if $FORCE; then
    echo "Mode: FORCE (re-running all steps)"
fi
echo ""

# =============================================================================
# STEP 0: System upgrade + kernel cleanup
# =============================================================================
if step_done "step0_dist_upgrade"; then
    log_skip "0/12: System upgrade (already done)"
else
    log_info "0/12: System upgrade (apt dist-upgrade)..."
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a

    apt-get update
    apt-get -y dist-upgrade

    apt-get -y autoremove --purge
    apt-get clean

    step_mark "step0_dist_upgrade"

    # Check if kernel was upgraded — requires reboot before continuing
    CURRENT_KERNEL=$(uname -r)
    NEWEST_KERNEL=$(ls -t /boot/vmlinuz-* 2>/dev/null | head -1 | sed 's|/boot/vmlinuz-||')
    if [ -n "$NEWEST_KERNEL" ] && [ "$NEWEST_KERNEL" != "$CURRENT_KERNEL" ]; then
        log_warn "============================================================"
        log_warn "Kernel upgraded: $CURRENT_KERNEL -> $NEWEST_KERNEL"
        log_warn "Reboot required! After reboot, re-run this script:"
        log_warn "  curl -H 'Cache-Control: no-cache' -fsSL \\"
        log_warn "    https://raw.githubusercontent.com/boneIO-eu/black_debian_images/main/scripts/setup_boneio.sh | sudo bash"
        log_warn "============================================================"
        exit 0
    fi
fi

# Remove old kernels (safe: uname -r = currently booted kernel after reboot)
CURRENT_KERNEL=$(uname -r)
OLD_KERNELS=$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/{print $2}' \
    | grep -v "$CURRENT_KERNEL" | grep -v 'linux-image-generic' || true)
if [ -n "$OLD_KERNELS" ]; then
    log_info "Removing old kernels: $OLD_KERNELS"
    apt-get -y purge $OLD_KERNELS
    apt-get -y autoremove --purge
    apt-get clean
fi

# =============================================================================
# STEP 1: UFW Firewall
# =============================================================================
if step_done "step1_ufw"; then
    log_skip "1/12: UFW firewall (already configured)"
else
    log_info "1/12: Configuring UFW firewall..."
    ufw allow 1883  # MQTT
    ufw allow 8090  # BoneIO Web
    ufw allow 8091  # Nginx proxy
    ufw logging off
    step_mark "step1_ufw"
    log_info "   UFW configured"
fi

# =============================================================================
# STEP 2: APT Install
# =============================================================================
if step_done "step2_apt_install"; then
    log_skip "2/12: APT packages (already installed)"
else
    log_info "2/12: Installing required packages..."
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    apt update
    apt install -y \
        libopenjp2-7-dev \
        python3-venv \
        libjpeg-dev \
        libyaml-dev \
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
    step_mark "step2_apt_install"
    log_info "   Packages installed"
fi

# =============================================================================
# STEP 3: APT Remove unnecessary packages
# =============================================================================
if step_done "step3_apt_remove"; then
    log_skip "3/12: APT remove (already cleaned)"
else
    log_info "3/12: Removing unnecessary packages..."
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
    step_mark "step3_apt_remove"
    log_info "   Unnecessary packages removed"
fi

# =============================================================================
# STEP 4: Disable unnecessary timers
# =============================================================================
if step_done "step4_services"; then
    log_skip "4/12: Services (already disabled)"
else
    log_info "4/12: Disabling unnecessary services..."
    # Kill apt auto-update processes first — they may hold dpkg locks and cause
    # 'systemctl stop' to hang indefinitely on slow storage.
    systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl kill --signal=TERM unattended-upgrades.service 2>/dev/null || true
    systemctl kill --signal=TERM apt-daily.service 2>/dev/null || true
    # Wait for dpkg lock to be released (max 60s)
    for i in $(seq 1 60); do
        if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then break; fi
        [ "$i" = "1" ] && log_info "   Waiting for dpkg lock to be released..."
        sleep 1
    done
    systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
    systemctl disable unattended-upgrades.service 2>/dev/null || true
    systemctl disable apt-daily.timer 2>/dev/null || true
    # Boot speed: iwd (WiFi manager, BBB has no WiFi) ~4.6s
    systemctl disable --now iwd.service 2>/dev/null || true
    # Boot speed: cockpit (web admin, boneIO has its own UI) ~1.9s
    systemctl disable --now cockpit.socket 2>/dev/null || true
    # Boot speed: headless box, no console keymap or font to configure ~5.8s
    systemctl disable --now keyboard-setup.service 2>/dev/null || true
    systemctl disable --now console-setup.service 2>/dev/null || true

    # Boot speed: AppArmor desktop profiles ~11.4s
    #
    # The apparmor package ships ~106 profiles in /etc/apparmor.d, nearly all
    # for desktop software (brave, chrome, Discord, steam, 1password,
    # MongoDB_Compass, Xorg, plasmashell, the sbuild-* and lxc-* families...).
    # apparmor.service loads every one at boot, ahead of networking.service on
    # the critical path. Measured with apparmor_parser --replace, warm cache:
    # 2.3s for 111 profiles vs 0.82s for 13.
    #
    # Keep-list rather than removal list, so a later apparmor package that adds
    # more desktop profiles cannot quietly restore the cost.
    #
    # Profiles belong to the apparmor package, so nothing is deleted — that
    # would fight dpkg on every upgrade. Symlinks in /etc/apparmor.d/disable/
    # are the mechanism apparmor_parser honours natively, and removing them
    # reverts the change.
    #
    # Container confinement is unaffected: dockerd generates its
    # 'docker-default' profile at runtime, not from /etc/apparmor.d.
    if [ -d /etc/apparmor.d ]; then
        APPARMOR_KEEP="unix-chkpwd usr.sbin.dhclient systemd-coredump runc crun
                       rootlesskit slirp4netns unprivileged_userns userbindmount
                       busybox toybox lsb_release nvidia_modprobe"
        mkdir -p /etc/apparmor.d/disable
        aa_disabled=0
        for prof in /etc/apparmor.d/*; do
            [ -f "$prof" ] || continue
            pname=$(basename "$prof")
            case " $(echo $APPARMOR_KEEP) " in
                *" $pname "*) continue ;;
            esac
            ln -sf "$prof" "/etc/apparmor.d/disable/$pname" && aa_disabled=$((aa_disabled+1))
        done
        log_info "   AppArmor: disabled ${aa_disabled} desktop profile(s)"
    fi

    # Login speed: keep the per-user systemd manager alive between sessions.
    #
    # user@1000.service takes ~4.1s to start on an AM335x. Without lingering it
    # is stopped when the last session closes, so every SSH login after a gap
    # pays that again: measured 6889ms cold versus 2715ms warm.
    #
    # Nothing orders against user@1000.service, so starting it at boot keeps it
    # off boneIO's critical path; it only competes for CPU, and boneIO runs at
    # CPUWeight=1000 against its default 100.
    #
    # Revert with: loginctl disable-linger boneio
    loginctl enable-linger ${BONEIO_USER} 2>/dev/null || true

    # ...but start that manager last, so it does not take CPU from boneIO
    # during boot. Note After=boneio.service would NOT work: boneio.service is
    # Type=simple, so systemd marks it active the moment it execs while its
    # Python imports run for ~20s more. multi-user.target is reached only once
    # everything else has started.
    mkdir -p /etc/systemd/system/user@1000.service.d
    cat > /etc/systemd/system/user@1000.service.d/50-boneio-defer.conf << 'EOF'
[Unit]
After=multi-user.target

[Service]
CPUWeight=20
IOWeight=20
EOF
    log_info "   Lingering enabled for ${BONEIO_USER}, manager deferred past boot"

    systemctl daemon-reload
    step_mark "step4_services"
    log_info "   Services disabled"
fi

# =============================================================================
# STEP 5: Docker + Node-RED + Caddy setup (directories only)
# =============================================================================
if step_done "step5_docker_dirs"; then
    log_skip "5/12: Docker directories (already set up)"
else
    log_info "5/12: Setting up Docker directories..."

    mkdir -p ${BONEIO_HOME}/docker/nodered/node-red/data
    mkdir -p ${BONEIO_HOME}/docker/nodered/caddy/data
    mkdir -p ${BONEIO_HOME}/docker/nodered/caddy/config
    chown -R ${BONEIO_USER}:${BONEIO_USER} ${BONEIO_HOME}/docker

    # Node-RED settings (small, stable — OK to write here)
    cat > ${BONEIO_HOME}/docker/nodered/node-red/settings.js << 'EOF'
module.exports = {
  httpAdminRoot: "/nodered",
  httpNodeRoot: "/nodered",
  ui: { path: "ui" },
};
EOF

    chown -R ${BONEIO_USER}:${BONEIO_USER} ${BONEIO_HOME}/docker
    log_info "   Docker directories created"
    # NOTE: docker-compose.yaml, caddy config files (init-certs.sh, 502.html)
    # are installed by boneio-migrate in STEP 9 below.

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
    step_mark "step5_docker_dirs"
fi

# =============================================================================
# STEP 6: Mosquitto — bootstrap passwd file (data only, not config)
# =============================================================================
if step_done "step6_mosquitto"; then
    log_skip "6/12: Mosquitto passwd (already bootstrapped)"
else
    log_info "6/12: Bootstrapping Mosquitto passwd file..."

    systemctl stop mosquitto 2>/dev/null || true
    rm -f /var/lib/mosquitto/mosquitto.db /var/lib/mosquitto/*.db
    touch /etc/mosquitto/passwd
    chown root:root /etc/mosquitto/passwd
    chmod 0644 /etc/mosquitto/passwd
    mosquitto_passwd -b /etc/mosquitto/passwd boneio boneio123
    mosquitto_passwd -b /etc/mosquitto/passwd homeassistant boneio123
    mosquitto_passwd -b /etc/mosquitto/passwd mqtt boneio123
    step_mark "step6_mosquitto"
    log_info "   Mosquitto passwd bootstrapped (config applied by migration)"
fi

# Steps 7-8 (journald, sudoers, OLED, systemd services) are applied below
# by boneio-migrate after pip install. No heredocs needed here.

# =============================================================================
# STEP 8: Early OLED boot splash (initramfs)
# =============================================================================
if step_done "step8_oled_splash"; then
    log_skip "8/12: OLED splash (already installed)"
else
    log_info "8/12: Installing early OLED boot splash (initramfs)..."
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
    step_mark "step8_oled_splash"
fi

# =============================================================================
# STEP 9: BoneIO application installation
# =============================================================================
log_info "9/12: Installing BoneIO application..."
mkdir -p ${BONEIO_HOME}/boneio
python3 -m venv ${BONEIO_HOME}/boneio/venv
${BONEIO_HOME}/boneio/venv/bin/pip install --upgrade pip
${BONEIO_HOME}/boneio/venv/bin/pip install --upgrade --pre boneio

# Ensure PyYAML has C extension (CLoader). pip install --upgrade may
# overwrite our bundled armv7l wheel with a PyPI sdist lacking libyaml.
# Re-install bundled wheel if CLoader is missing.
if ! ${BONEIO_HOME}/boneio/venv/bin/python -c "from yaml import CLoader" 2>/dev/null; then
    PYYAML_WHL=$(find ${BONEIO_HOME}/boneio/venv/lib/python*/site-packages/boneio/migrations/assets/wheels/ \
        -name 'pyyaml-*-linux_armv7l*.whl' -o -name 'PyYAML-*-linux_armv7l*.whl' 2>/dev/null | head -1)
    if [ -n "$PYYAML_WHL" ]; then
        log_info "   PyYAML missing CLoader, installing bundled wheel: $(basename $PYYAML_WHL)"
        ${BONEIO_HOME}/boneio/venv/bin/pip install --force-reinstall --no-deps --no-index "$PYYAML_WHL"
    else
        log_warn "   PyYAML missing CLoader and no bundled wheel found, rebuilding from source..."
        ${BONEIO_HOME}/boneio/venv/bin/pip install --force-reinstall --no-binary PyYAML PyYAML
    fi
fi

# Copy example configs (exclude __init__.py and __pycache__ to avoid
# creating a shadow 'boneio' package in /home/boneio/boneio/ that would
# hide the real one in site-packages and break migrations imports)
BONEIO_PKG_PATH=$(${BONEIO_HOME}/boneio/venv/bin/python -c "import boneio; print(boneio.__path__[0])")
if [ -d "${BONEIO_PKG_PATH}/example_config" ]; then
    rsync -a --exclude='__init__.py' --exclude='__pycache__' \
        ${BONEIO_PKG_PATH}/example_config/ ${BONEIO_HOME}/boneio/ 2>/dev/null || \
    cp -r ${BONEIO_PKG_PATH}/example_config/* ${BONEIO_HOME}/boneio/ 2>/dev/null || true
    # Safety: remove __init__.py if it leaked (breaks boneio.migrations import)
    rm -f ${BONEIO_HOME}/boneio/__init__.py
    rm -rf ${BONEIO_HOME}/boneio/__pycache__
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
    # Apply all migrations via MigrationRunner.
    # We run as root (setup_boneio.sh is already root) so boneio-migrate helper
    # can write to /etc/systemd, /usr/sbin, etc. without sudoers issues.
    log_info "   Applying system migrations..."
    VENV_DIR="${BONEIO_HOME}/boneio/venv"
    log_info "   Using venv: ${VENV_DIR}"
    log_info "   Python: $(${VENV_DIR}/bin/python3 --version 2>&1)"

    # CRITICAL: must cd away from /home/boneio/ before running Python!
    # /home/boneio/boneio/ directory shadows the real boneio package
    # via Python 3.3+ namespace packages (even without __init__.py).
    cd /tmp

    # Also force-remove __init__.py if it leaked from example_config copy
    if [ -f "${BONEIO_HOME}/boneio/__init__.py" ]; then
        log_warn "   Removing shadow __init__.py from ${BONEIO_HOME}/boneio/"
        rm -f "${BONEIO_HOME}/boneio/__init__.py"
    fi
    rm -rf "${BONEIO_HOME}/boneio/__pycache__"

    # Verify boneio.migrations is importable
    ${VENV_DIR}/bin/python3 -c "import boneio.migrations; print(f'migrations at: {boneio.migrations.__file__}')" 2>&1 || {
        log_error "   boneio.migrations not importable! Checking sys.path:"
        ${VENV_DIR}/bin/python3 -c "import sys; print('\n'.join(sys.path))" 2>&1
        log_error "   CWD: $(pwd)"
        log_error "   Listing site-packages:"
        ls ${VENV_DIR}/lib/python*/site-packages/boneio/ 2>&1 || true
    }
    ${VENV_DIR}/bin/python3 -c "
import logging, sys
logging.basicConfig(level=logging.INFO, stream=sys.stdout, format='%(levelname)s: %(message)s')
from boneio.migrations.runner import MigrationRunner
r = MigrationRunner()
ok = r.apply_all()
if not ok:
    print('ERROR: Migration apply_all() returned False', file=sys.stderr)
    sys.exit(1)
print(f'Migrations applied. Status: {r.status}')
"
    if [ $? -ne 0 ]; then
        log_error "   Migration apply failed!"
        log_error "   Check /var/log/boneio-migrate.log for details"
    else
        log_info "   All migrations applied successfully"
    fi
else
    log_warn "boneio-migrate bootstrap not found, skipping migration apply"
fi

log_info "   BoneIO application installed"

# Copy docker-compose.yaml from package (migration doesn't install it to avoid
# overwriting cloud users' compose on upgrade — but new installs need it)
log_info "   Installing docker-compose.yaml from package..."
cd /tmp
${BONEIO_HOME}/boneio/venv/bin/python3 -c "
from importlib.resources import files
src = files('boneio.core.cloud.data').joinpath('docker-compose.yaml')
print(src.read_text(), end='')
" > ${BONEIO_HOME}/docker/nodered/docker-compose.yaml
chown ${BONEIO_USER}:${BONEIO_USER} ${BONEIO_HOME}/docker/nodered/docker-compose.yaml

# Pull Docker images so Node-RED + Caddy work out of the box
log_info "   Starting Docker daemon..."
# Clean stale bridge state (prevents 'networks have same bridge name' error)
systemctl stop docker 2>/dev/null || true
ip link delete docker0 2>/dev/null || true
rm -rf /var/lib/docker/network 2>/dev/null || true
systemctl start docker 2>/dev/null || true
log_info "   Pulling Docker images (Node-RED + Caddy)..."
export HOSTNAME=$(hostname)
cd ${BONEIO_HOME}/docker/nodered
# Remove stale containers/networks from previous image runs
docker compose down --remove-orphans 2>&1 || true
docker network prune -f 2>/dev/null || true
docker compose pull 2>&1 || log_warn "   Docker image pull failed (will retry on first boot)"
docker compose up -d 2>&1 || log_warn "   Docker compose up failed"
log_info "   Docker containers started"
# NOTE: Don't 'docker compose stop' before poweroff — restart:unless-stopped
# needs containers to have been running to auto-start on next boot.

# =============================================================================
# STEP 10: Device Tree Overlay
# =============================================================================
log_info "10/12: Building and installing Device Tree Overlay..."
cd /opt/source
if [ -d "black-pins-overlay" ]; then
    log_info "   Updating existing overlay repo..."
    cd black-pins-overlay
    git fetch origin 2>/dev/null || true
    git reset --hard origin/main 2>/dev/null || git reset --hard origin/master 2>/dev/null || true
else
    log_info "   Cloning overlay repo..."
    git clone https://github.com/boneIO-eu/black-pins-overlay.git
    cd black-pins-overlay
fi
chmod +x build_boneio_black_pins.sh Makefile
./build_boneio_black_pins.sh

# Configure uEnv.txt — works regardless of whether lines are commented or not
UENV="/boot/firmware/uEnv.txt"
if [ ! -f "$UENV" ]; then
    UENV="/boot/uEnv.txt"
fi

# Ensure enable_uboot_overlays=1 is uncommented
sed -i 's/^#enable_uboot_overlays=1/enable_uboot_overlays=1/' "$UENV"

# The normalization below anchors its insert on this line, so it must exist.
# Without this guard a uEnv.txt lacking the line entirely would have its overlay
# declaration deleted and nothing inserted in its place.
if ! grep -q '^enable_uboot_overlays=1' "$UENV"; then
    echo 'enable_uboot_overlays=1' >> "$UENV"
    log_warn "   enable_uboot_overlays=1 was missing, appended"
fi

# Normalize the overlay declaration to EXACTLY ONE line.
#
# A controller was found in the field with two active declarations:
#     uboot_overlay_addr0=BONEIO-BLACK-PINS.dtbo          <- legacy alias (v0.4-v0.8)
#     uboot_overlay_addr0=BONEIO-BLACK-PINS-v1.0.dtbo     <- correct for that board
# uEnv.txt is consumed by U-Boot's "env import", so the LAST line wins. The
# duplicate is not harmless bookkeeping: the two lines select different pinmux.
# On a v1.0+ board the legacy alias would put GPIO 1-Wire on P9_12 instead of
# the buzzer and leave DS2484 undeclared; on a v0.4-v0.8 board the reverse.
#
# Therefore NEVER guess the board version here. Preserve whatever U-Boot is
# already using — the last active declaration — and only fall back to a default
# when the file declares nothing at all. Getting this wrong silently degrades a
# working controller, and the symptom (1-Wire missing, wrong pin behaviour) does
# not point back at uEnv.txt.
#
# Override for a fresh image with no declaration yet:
#     BONEIO_OVERLAY=BONEIO-BLACK-PINS-v1.0.dtbo ./setup_boneio.sh
#
# The overlay is referenced by BARE FILENAME on purpose: U-Boot resolves it
# against /boot/dtbs/$uname_r/, so it keeps working after a kernel upgrade.
# A hardcoded path does not.

OVERLAY_LINES_BEFORE=$(grep -c '^[#[:space:]]*uboot_overlay_addr0=.*BONEIO-BLACK-PINS' "$UENV" || true)

# Last ACTIVE declaration = what U-Boot uses today. Strip any path prefix.
CURRENT_OVERLAY=$(sed -n 's|^uboot_overlay_addr0=.*/\?\(BONEIO-BLACK-PINS[^[:space:]#]*\.dtbo\).*|\1|p' "$UENV" | tail -1)

if [ -n "$CURRENT_OVERLAY" ]; then
    if [ "$CURRENT_OVERLAY" = "BONEIO-BLACK-PINS.dtbo" ]; then
        # Legacy alias is documented as identical to v0.4-v0.8. Make it explicit
        # so future version comparisons are unambiguous.
        BONEIO_OVERLAY="BONEIO-BLACK-PINS-v0.4-v0.8.dtbo"
        log_info "   Overlay: legacy alias -> ${BONEIO_OVERLAY}"
    else
        BONEIO_OVERLAY="$CURRENT_OVERLAY"
        log_info "   Overlay: preserving existing ${BONEIO_OVERLAY}"
    fi
else
    BONEIO_OVERLAY="${BONEIO_OVERLAY:-BONEIO-BLACK-PINS-v0.4-v0.8.dtbo}"
    log_info "   Overlay: none declared, defaulting to ${BONEIO_OVERLAY}"
fi

sed -i '/^[#[:space:]]*uboot_overlay_addr0=.*BONEIO-BLACK-PINS/d' "$UENV"
sed -i "/^enable_uboot_overlays=1/a uboot_overlay_addr0=${BONEIO_OVERLAY}" "$UENV"

if [ "$OVERLAY_LINES_BEFORE" -gt 1 ]; then
    log_warn "   Collapsed ${OVERLAY_LINES_BEFORE} duplicate overlay declarations into one"
fi

# Fix the malformed 'earlycon' kernel argument.
#
# The BeagleBoard base image ships a bare "earlycon" in cmdline. On this DT
# platform the kernel cannot resolve it and rejects the option outright:
#     [    0.000000] Malformed early option 'earlycon'
# The result is no boot console at all until the 8250 driver registers at
# ~3.9 s, so any hang or panic before that point is completely invisible —
# while the cmdline suggests early console is available. Give it the explicit
# UART0 MMIO address for AM335x.
if grep -q '^cmdline=.*[[:space:]]earlycon\([[:space:]]\|$\)' "$UENV"; then
    sed -i 's/^\(cmdline=.*\)[[:space:]]earlycon\([[:space:]]\|$\)/\1 earlycon=8250,mmio32,0x44e09000\2/' "$UENV"
    log_info "   Fixed malformed 'earlycon' -> earlycon=8250,mmio32,0x44e09000"
fi

# Uncomment disable lines (idempotent — works if already uncommented)
sed -i \
    -e 's/^#disable_uboot_overlay_video=1/disable_uboot_overlay_video=1/' \
    -e 's/^#disable_uboot_overlay_audio=1/disable_uboot_overlay_audio=1/' \
    -e 's/^#disable_uboot_overlay_wireless=1/disable_uboot_overlay_wireless=1/' \
    -e 's/^uboot_overlay_pru=/#uboot_overlay_pru=/' \
    "$UENV"

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

log_info "Validating installation..."
VALIDATE_OK=true
for check_path in \
    "/etc/systemd/system/boneio.service" \
    "${BONEIO_HOME}/boneio/venv/bin/python3" \
    "/usr/sbin/oled_msg.py" \
    "/usr/sbin/oled_msg.sh" \
    "/usr/sbin/boneio-migrate"; do
    if [ -e "$check_path" ] || [ -L "$check_path" ]; then
        log_info "   ✅ $check_path"
    else
        log_error "   ❌ MISSING: $check_path"
        VALIDATE_OK=false
    fi
done

# Check boneio package is importable
cd /tmp
BONEIO_VER=$(${BONEIO_HOME}/boneio/venv/bin/python3 -c "from boneio.version import __version__; print(__version__)" 2>/dev/null || echo "FAIL")
if [ "$BONEIO_VER" = "FAIL" ]; then
    log_error "   ❌ boneio package not importable!"
    VALIDATE_OK=false
else
    log_info "   ✅ boneio ${BONEIO_VER} installed"
fi

if [ "$VALIDATE_OK" = false ]; then
    log_error "Validation failed! Aborting (system will NOT shutdown)."
    exit 1
fi
log_info "Validation passed ✅"

log_info "11/12: Running final cleanup..."

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

# Remove journal directories now that machine-id is cleared.
#
# /var/log/journal/ and log2ram's disk copy hold one subdirectory per
# machine-id. journald manages only the one matching /etc/machine-id, so once a
# new id is generated on first boot the old directory becomes invisible to
# journalctl --vacuum-* and to SystemMaxUse, and is never cleaned again.
#
# That is not just wasted space: log2ram rsyncs the whole tree on every boot,
# with --no-whole-file, so it checksums the apparent size of every sparse
# journal file. A field controller had accumulated nine machine-id directories
# and log2ram was spending 18.3 s per boot on them.
#
# 'journalctl --vacuum-time=0d' above does not touch these — it only knows the
# current machine-id, which we are about to invalidate. So clear them here,
# while we still know the image is being sealed.
rm -rf /var/log/journal/* /var/hdd.log/journal/* 2>/dev/null || true

rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -rf /var/lib/dhcp/*
rm -rf /var/lib/NetworkManager/*.lease
rm -f /etc/ssh/ssh_host_*
touch /etc/bbb.io/ssh_regenerate
find /var/log -type f -exec truncate -s 0 {} \;
rm -rf /tmp/*
rm -rf /var/tmp/*
# Clear mosquitto retained messages (boneio may have published during setup)
systemctl stop mosquitto 2>/dev/null || true
rm -f /var/lib/mosquitto/mosquitto.db /var/lib/mosquitto/*.db

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
