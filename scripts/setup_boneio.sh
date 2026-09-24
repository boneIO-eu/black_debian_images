#!/bin/bash
## BoneIO Black - Complete System Setup Script
## Usage: curl -H 'Cache-Control: no-cache' -fsSL https://raw.githubusercontent.com/boneIO-eu/black_debian_images/main/scripts/setup_boneio.sh | sudo bash
## Options: --no-cleanup  Skip final cleanup step (for testing on a live system)
##          --force       Force re-run all steps (ignore completion markers)
##
## Environment:
##   BONEIO_VERSION=1.6.0.devN   which boneIO goes into the image
##   BONEIO_USER_PASSWORD=...    ship a WORKING password for the boneio account
##                               instead of locking it. For images that have to
##                               answer automation. Never for something that
##                               leaves the building.
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
SCRIPT_VERSION="2026-09-24.2"

# Which boneIO goes into the image.
#
# This has to be named, and the reason is not obvious. `pip install --upgrade
# boneio` resolves to the newest *stable* release, and the whole 1.6 security
# series is published as pre-releases (1.6.0.devN). PyPI's latest stable is
# still 1.5.5, so the unpinned form silently builds an image on the 1.5 line:
# no signed migrations, no closed-vocabulary helpers, no certificate work — the
# migrations that harden the device are not even present to be run, and nothing
# in the build fails to say so.
#
# Pinned rather than `--pre`, because an image is a release artifact and has to
# be reproducible: `--pre` would follow to whatever dev release happened to be
# newest at build time, and would also let pre-releases in for every
# dependency. An exact `==` on a pre-release version is honoured by pip without
# `--pre`, which is exactly the narrow permission wanted here.
#
# Override for a one-off build:  BONEIO_VERSION=1.6.0.devN ./setup_boneio.sh
#
# Bumping this is what carries app changes into a new image. The flasher script
# is copied from this repo when a card is written, so changes there need no new
# image — but anything in the boneIO application does, and that is what this
# line decides.
BONEIO_VERSION="${BONEIO_VERSION:-1.6.0.dev13}"

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

    # Expand rootfs to fill the entire SD card — the image from
    # create_rootfs_img.sh is shrunk to ~2.7 GB, but the physical SD card
    # can be 8–32 GB. Without this, dist-upgrade fails with ENOSPC.
    ROOT_DEV=$(findmnt -n -o SOURCE /)
    if [ -n "$ROOT_DEV" ]; then
        # Extract disk device and partition number (e.g. /dev/mmcblk0p3 → /dev/mmcblk0, 3)
        DISK_DEV=$(echo "$ROOT_DEV" | sed 's/p[0-9]*$//')
        PART_NUM=$(echo "$ROOT_DEV" | grep -o '[0-9]*$')

        if [ -b "$DISK_DEV" ] && [ -n "$PART_NUM" ]; then
            CURRENT_SIZE=$(df --output=size / | tail -1 | tr -d ' ')
            # Only expand if rootfs < 4 GB (4194304 KB) — avoids re-running on eMMC
            if [ "$CURRENT_SIZE" -lt 4194304 ] 2>/dev/null; then
                log_info "   Expanding rootfs partition ($ROOT_DEV) to fill SD card..."
                if command -v growpart &>/dev/null; then
                    growpart "$DISK_DEV" "$PART_NUM" || true
                else
                    log_warn "   growpart not found, trying sfdisk..."
                    echo ", +" | sfdisk -N "$PART_NUM" "$DISK_DEV" --force --no-reread 2>/dev/null || true
                    partprobe "$DISK_DEV" 2>/dev/null || true
                fi
                resize2fs "$ROOT_DEV" || true
                log_info "   Rootfs expanded: $(df -h / | awk 'NR==2{print $2}')"
            fi
        fi
    fi

    # Free disk space BEFORE upgrade — belt and suspenders
    log_info "   Freeing disk space before upgrade..."
    apt-get clean
    docker system prune -af 2>/dev/null || true
    rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
    journalctl --vacuum-size=1M 2>/dev/null || true

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
    # These rules are staged, not active: nothing here runs 'ufw enable', so
    # the device ships with no firewall. Left as is on purpose — turning a
    # default-deny firewall on unattended, over the network, is how a remote
    # controller becomes a brick.
    #
    # 22 and 8443 are in the list for exactly that reason. Without them, the
    # first person to run 'ufw enable' loses SSH and the TLS panel in the same
    # second, with only the plain-HTTP ports still answering.
    ufw allow 22    # SSH — or enabling the firewall locks the operator out
    ufw allow 1883  # MQTT
    ufw allow 8090  # boneIO web panel
    ufw allow 8091  # Caddy, plain HTTP
    ufw allow 8443  # Caddy, TLS — the port the panel should be reached on
    ufw logging off
    step_mark "step1_ufw"
    log_info "   UFW rules staged (firewall is NOT enabled — 'ufw status' says inactive)"
fi

# =============================================================================
# STEP 1b: SSH login hardening
# =============================================================================
if step_done "step1b_sshd"; then
    log_skip "1b/12: SSH hardening (already applied)"
else
    log_info "1b/12: Hardening SSH logins..."

    # The web login has been throttled since 1.6; SSH was left on the stock
    # settings, so guessing was bounded only by patience. This does not lock
    # anyone out — key auth and password auth both keep working, there are
    # just fewer attempts per connection and less time to make them.
    SSHD_DROPIN="/etc/ssh/sshd_config.d/10-boneio-hardening.conf"
    mkdir -p /etc/ssh/sshd_config.d
    cat > "${SSHD_DROPIN}" <<'SSHD_EOF'
# boneIO login hardening. Managed by setup_boneio.sh — edit at your own risk.
# Three guesses per connection instead of six, and a shorter window to make
# them in. Root has no reason to log in over SSH on this device.
MaxAuthTries 3
LoginGraceTime 20
PermitRootLogin no
SSHD_EOF
    chmod 0644 "${SSHD_DROPIN}"

    # Validate before reloading. A config sshd refuses to parse would take the
    # daemon down on restart, and on a device reached only over the network
    # that is unrecoverable without a serial console.
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        step_mark "step1b_sshd"
        log_info "   SSH hardened (MaxAuthTries 3, LoginGraceTime 20, no root login)"
    else
        rm -f "${SSHD_DROPIN}"
        log_warn "   sshd rejected the hardening drop-in; reverted and left SSH untouched"
        sshd -t 2>&1 | sed 's/^/     /' || true
    fi
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

    # The boneio account is deliberately NOT put in the docker group. That
    # group is root without a password and without a sudo rule: the daemon
    # starts containers as root, so anyone who can reach its socket can ask
    # for one with the host filesystem mounted. Container management goes
    # through /usr/sbin/boneio-containers instead. The docker commands further
    # down in this script run as root, not as ${BONEIO_USER}.
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

    # PackageKit and AppStream: purged, not removed. Their apt hooks are
    # conffiles (/etc/apt/apt.conf.d/20packagekit, 50appstream), and a plain
    # remove leaves them behind. 20packagekit pings packagekitd over D-Bus
    # after every apt update and dpkg run with a 4 s timeout the BeagleBone
    # cannot meet ("Error: Timeout was reached" in the panel's update log);
    # 50appstream downloads DEP-11 metadata on every update. Nothing boneIO
    # runs uses either. Same list as boneIO migration 1.6.20, which does this
    # on devices already in the field — keep the two the same.
    apt-get purge -y \
        cockpit-packagekit \
        packagekit-tools \
        packagekit \
        libpackagekit-glib2-18 \
        appstream \
        libappstream5 2>/dev/null || true
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
    # The apt timers are NOT disabled any more. They run the automatic
    # security updates (boneIO migration 1.6.22: Debian-Security only, never a
    # reboot, switchable in the panel), which is why they are on by default.
    # 1.6.22 also drops their boot-time catch-up and lowers their CPU weight,
    # which was the reason they used to be switched off. Stopping them above
    # is only so they do not hold the dpkg lock while this script runs.
    # unattended-upgrades.service is the install-on-shutdown hook, not used.
    systemctl disable unattended-upgrades.service 2>/dev/null || true
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

    # One password per device, not one per product line (F-05).
    #
    # 'boneio123' was identical on every unit ever shipped and documented in
    # UPDATE.md, so knowing one device's broker meant knowing all of them.
    #
    # Only accounts that do not exist yet are created. This step re-runs on a
    # live device — step markers expire after 24h — and the previous version
    # rewrote all three passwords back to the shared default every time,
    # silently undoing whatever the owner had set. Creating only what is
    # missing makes the step safe to repeat.
    #
    # 'homeassistant' and 'mqtt' exist for the owner's integrations and get
    # random values they are meant to replace; the panel can set all three
    # without a sudo password (see /etc/sudoers.d/boneio), so nothing is lost
    # by not knowing them.
    for mqtt_account in boneio homeassistant mqtt; do
        if grep -q "^${mqtt_account}:" /etc/mosquitto/passwd 2>/dev/null; then
            log_info "   MQTT account '${mqtt_account}' already exists, left alone"
            continue
        fi
        mqtt_generated="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
        mosquitto_passwd -b /etc/mosquitto/passwd "${mqtt_account}" "${mqtt_generated}"
        if [ "${mqtt_account}" = "boneio" ]; then
            # The app's own account: kept so the config step below can point
            # mqtt.yaml at it, possibly in a later invocation. Root-only, since
            # it is the cleartext the app will authenticate with.
            install -d -m 0700 /etc/boneio
            printf '%s\n' "${mqtt_generated}" > /etc/boneio/mqtt-boneio.pass
            chmod 0600 /etc/boneio/mqtt-boneio.pass
        fi
        log_info "   MQTT account '${mqtt_account}' created with a per-device password"
    done
    unset mqtt_generated
    # After the writes, not before: mosquitto_passwd rewrites the file and its
    # own choice of mode would otherwise be the one that survives.
    #
    # 0640 root:mosquitto, not 0644. The broker runs as mosquitto and reads the
    # file through the group; world-read let every local account take the
    # hashes for an offline crack (F-11).
    chown root:mosquitto /etc/mosquitto/passwd
    chmod 0640 /etc/mosquitto/passwd
    step_mark "step6_mosquitto"
    log_warn "   Newly created MQTT accounts have random passwords — set your own in"
    log_warn "   the panel (Settings -> MQTT passwords) before pointing HA at them."
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
log_info "   Installing boneio==${BONEIO_VERSION}"
${BONEIO_HOME}/boneio/venv/bin/pip install --upgrade "boneio==${BONEIO_VERSION}"

# Say out loud what landed. The failure this guards against is not pip erroring
# — it is pip succeeding with a version nobody intended, which then shows up
# months later as a controller in a cabinet missing every hardening migration.
BONEIO_INSTALLED="$(${BONEIO_HOME}/boneio/venv/bin/python3 -c \
    'import importlib.metadata as m; print(m.version("boneio"))' 2>/dev/null || echo "unknown")"
if [ "${BONEIO_INSTALLED}" != "${BONEIO_VERSION}" ]; then
    log_error "   Asked for boneio==${BONEIO_VERSION} but got '${BONEIO_INSTALLED}'"
    log_error "   Refusing to build an image on a version nobody chose."
    exit 1
fi
log_info "   boneio ${BONEIO_INSTALLED} installed"

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

# Set initial default 32x10 config in /home/boneio/boneio/
rm -f ${BONEIO_HOME}/boneio/__init__.py 2>/dev/null || true
rm -rf ${BONEIO_HOME}/boneio/__pycache__ 2>/dev/null || true
if [ -d "${BONEIO_HOME}/.cache/boneio_configs/32x10" ]; then
    cp ${BONEIO_HOME}/.cache/boneio_configs/32x10/*.yaml ${BONEIO_HOME}/boneio/ 2>/dev/null || true
fi

# Point the app config at this device's broker password.
#
# Deliberately keyed on the literal default: the substitution only fires where
# a config still says 'boneio123'. A device whose owner has already set their
# own password is left alone, which is what makes this safe to re-run and safe
# on a device that has been in service for a year.
#
# Both the live config and the cached per-variant copies are updated, so
# switching board type later does not reintroduce the shipped default.
# Which configs still carry the shipped default? Asked first, because the
# answer decides whether anything may be touched at all.
MQTT_STALE_CONFIGS=()
for mqtt_cfg in ${BONEIO_HOME}/boneio/mqtt.yaml \
                ${BONEIO_HOME}/.cache/boneio_configs/*/mqtt.yaml; do
    [ -f "$mqtt_cfg" ] || continue
    grep -q '^password: boneio123$' "$mqtt_cfg" && MQTT_STALE_CONFIGS+=("$mqtt_cfg")
done

if [ ${#MQTT_STALE_CONFIGS[@]} -eq 0 ]; then
    log_info "   No mqtt.yaml carries the shipped default — broker credentials left alone"
else
    # Order matters here. An earlier version generated a password first and
    # substituted afterwards, which meant a device whose owner had already set
    # their own password got the broker rotated while the config kept the old
    # value — the app would come back up unable to reach its own broker. So
    # nothing is rotated unless a config is demonstrably still on the default.
    if [ -s /etc/boneio/mqtt-boneio.pass ]; then
        MQTT_BONEIO_PASS="$(cat /etc/boneio/mqtt-boneio.pass)"
    else
        # Bootstrapped by an older build, so the broker still holds the shared
        # default for this account. Rotate it — we own both of its sides.
        MQTT_BONEIO_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
        install -d -m 0700 /etc/boneio
        printf '%s\n' "${MQTT_BONEIO_PASS}" > /etc/boneio/mqtt-boneio.pass
        chmod 0600 /etc/boneio/mqtt-boneio.pass
        mosquitto_passwd -b /etc/mosquitto/passwd boneio "${MQTT_BONEIO_PASS}"
        # mosquitto_passwd rewrites the file and picks its own mode, so the
        # F-11 permissions have to be re-applied after every write to it — not
        # just after the bootstrap in step 6.
        chown root:mosquitto /etc/mosquitto/passwd
        chmod 0640 /etc/mosquitto/passwd
        systemctl reload mosquitto 2>/dev/null || true
        log_info "   Rotated the broker's 'boneio' password away from the shipped default"
    fi

    for mqtt_cfg in "${MQTT_STALE_CONFIGS[@]}"; do
        sed -i "s|^password: boneio123$|password: ${MQTT_BONEIO_PASS}|" "$mqtt_cfg"
    done
    log_info "   Pointed ${#MQTT_STALE_CONFIGS[@]} mqtt.yaml file(s) at this device's password"
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

# Do not resurrect the legacy helper on a device that has already retired it.
#
# install-helper.sh creates /usr/sbin/boneio-migrate unconditionally, and
# migration 1.6.6 removes it — that removal is where F-04 closes. On a second
# run of this script the order is: bootstrap re-creates the helper, then
# apply_all() skips 1.6.6 because it is already marked applied, and the device
# ends up with the retired helper back and its NOPASSWD rule with it. The
# hardening is undone by re-running the setup, silently.
#
# The runner needs *a* helper, not this one: MigrationRunner falls back to
# boneio-migrate-v2 when it is installed and its selftest passes, so a device
# that has pivoted needs no legacy bootstrap at all.
BOOTSTRAP_LEGACY=true
if [ -x /usr/sbin/boneio-migrate-v2 ] && sudo -n /usr/sbin/boneio-migrate-v2 --selftest >/dev/null 2>&1; then
    BOOTSTRAP_LEGACY=false
    log_info "   boneio-migrate-v2 is healthy — not installing the retired legacy helper"
    if [ -e /usr/sbin/boneio-migrate ] || [ -e /etc/sudoers.d/boneio-migrate ]; then
        rm -f /usr/sbin/boneio-migrate /etc/sudoers.d/boneio-migrate
        log_info "   Removed a legacy helper left over from an earlier run (F-04)"
    fi
fi

if [ "$BOOTSTRAP_LEGACY" = true ] && [ ! -f "${BONEIO_INSTALL_HELPER}" ]; then
    log_warn "boneio-migrate bootstrap not found, skipping migration apply"
else
    if [ "$BOOTSTRAP_LEGACY" = true ]; then
        bash "${BONEIO_INSTALL_HELPER}" "${BONEIO_MIGRATE_HELPER}" "${BONEIO_MIGRATE_SUDOERS}"
    fi
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
fi

# Pre-compile Python bytecode (.pyc) to speed up cold startup
log_info "   Pre-compiling Python bytecode..."
${BONEIO_HOME}/boneio/venv/bin/python3 -m compileall -q ${BONEIO_HOME}/boneio/venv

# Install BoneIO configs for all variants (32x10, 24x16, cover, cover_mix, tester)
log_info "   Installing BoneIO configs in ${BONEIO_HOME}/.cache/boneio_configs/..."
CONFIGS_DIR="${BONEIO_HOME}/.cache/boneio_configs"
mkdir -p "$CONFIGS_DIR"

# Board revision whose configs get installed. The repo keeps one directory per
# revision (configs/1.0, configs/1.1); the device-side cache stays flat, so the
# rest of the tooling does not need to know which one was picked.
BOARD_CONFIG_VERSION="${BOARD_CONFIG_VERSION:-1.1}"
log_info "   Board config revision: ${BOARD_CONFIG_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/../configs/$BOARD_CONFIG_VERSION" ]; then
    cp -r "$SCRIPT_DIR/../configs/$BOARD_CONFIG_VERSION"/* "$CONFIGS_DIR/"
else
    # Fallback when running piped via curl: download configs from GitHub
    for variant in 32x10 24x16 cover cover_mix tester; do
        mkdir -p "$CONFIGS_DIR/$variant"
        for f in config.yaml event.yaml binary_sensor.yaml mqtt.yaml adc.yaml output32x10A.yaml output24x16A.yaml outputCover.yaml outputCoverMix.yaml cover.yaml; do
            curl -fsSL "https://raw.githubusercontent.com/boneIO-eu/black_debian_images/main/configs/$BOARD_CONFIG_VERSION/$variant/$f" -o "$CONFIGS_DIR/$variant/$f" 2>/dev/null || true
        done
    done
fi
# A 404 leaves curl's -o file behind as an empty stub; drop those so a missing
# variant looks missing instead of looking like an empty config.
find "$CONFIGS_DIR" -type f -name '*.yaml' -size 0 -delete 2>/dev/null || true

# Pre-generate schema cache and config caches for all 5 variants
log_info "   Pre-generating schema cache and config caches..."
cd /tmp
su - ${BONEIO_USER} -c "
cd /tmp
${BONEIO_HOME}/boneio/venv/bin/python3 -c '
import os
import boneio.core.config.yaml_util as y

# 1. Warm schema cache (~/.cache/boneio/schema.pkl)
y._load_schema()

# 2. Warm config cache for each of the 5 variants in ~/.cache/boneio_configs
configs_dir = os.path.expanduser(\"~/.cache/boneio_configs\")
for variant in [\"32x10\", \"24x16\", \"cover\", \"cover_mix\", \"tester\"]:
    cfg_path = os.path.join(configs_dir, variant, \"config.yaml\")
    if os.path.isfile(cfg_path):
        try:
            y.load_config_from_file(cfg_path)
            print(f\"   Cached {variant}: {cfg_path}\")
        except Exception as e:
            print(f\"   Warning: failed to cache {variant}: {e}\")

# 3. If /home/boneio/boneio/config.yaml is present, warm it as well
main_cfg = \"${BONEIO_HOME}/boneio/config.yaml\"
if os.path.isfile(main_cfg):
    try:
        y.load_config_from_file(main_cfg)
        print(f\"   Cached: {main_cfg}\")
    except Exception as e:
        print(f\"   Warning: failed to cache {main_cfg}: {e}\")
'
"
chown -R ${BONEIO_USER}:${BONEIO_USER} ${BONEIO_HOME} 2>/dev/null || true

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
    BONEIO_OVERLAY="${BONEIO_OVERLAY:-BONEIO-BLACK-PINS-v1.0.dtbo}"
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
    "/usr/sbin/boneio-migrate-v2" \
    "/usr/sbin/boneio-containers" \
    "/usr/sbin/boneio-helpers-heal" \
    "/usr/sbin/boneio-system"; do
    if [ -e "$check_path" ] || [ -L "$check_path" ]; then
        log_info "   ✅ $check_path"
    else
        log_error "   ❌ MISSING: $check_path"
        VALIDATE_OK=false
    fi
done

# The old helper has to be GONE, not present.
#
# /usr/sbin/boneio-migrate took a migration plan from whoever called it, and
# migration 1.6.6 removes it — that removal is where F-04 actually closes.
# Until now this list asked for the retired helper and failed the build when
# the hardening had worked, which is the most confusing way a check can be
# wrong: it reports success as failure and sends you looking for a break that
# is not there.
#
# 1.6.6 only runs after `boneio-migrate-v2 --selftest` returns zero, so the old
# helper still being here means the pivot did not finish and the device kept
# the channel that was meant to close.
if [ -e "/usr/sbin/boneio-migrate" ]; then
    log_error "   ❌ STILL PRESENT: /usr/sbin/boneio-migrate"
    log_error "      Migration 1.6.6 retires it. If 1.6.6.applied exists in"
    log_error "      /var/lib/boneio/migrations.d/ then something re-created"
    log_error "      the helper after the migration ran — the migration will"
    log_error "      not run again to remove it. If it does not exist, the"
    log_error "      v2 selftest failed; see /var/log/boneio-migrate.log."
    VALIDATE_OK=false
else
    log_info "   ✅ /usr/sbin/boneio-migrate retired (F-04)"
fi

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

# Drop the build-time sudo rule (F-04).
#
# build_image_usb.sh writes '${BONEIO_USER} ALL=(ALL) NOPASSWD: ALL' to
# /etc/sudoers.d/boneio-setup so the unattended setup can run, and until now
# nothing took it away again — every shipped image granted the service account
# full root with no credential at all. It has done its job by this point.
#
# Only in the sealing path: this whole step is skipped under --no-cleanup, so a
# device in service never has its sudo configuration changed underneath it.
if [ -e /etc/sudoers.d/boneio-setup ]; then
    rm -f /etc/sudoers.d/boneio-setup
    log_info "   Removed the build-time NOPASSWD sudo rule"
fi

# Lock the account: no password login at all until the owner sets one.
#
# The build gives this account 'Black', shared by every unit and published,
# and the account carries a password-gated (ALL:ALL) ALL — so that password is
# the root password. This is the part of F-04 tightening sudo cannot fix: it is
# the credential, not the privilege.
#
# Earlier images expired it instead (chage -d 0). That forced a change on
# whoever logged in first, which need not be the owner: anyone who reached a
# fresh device over SSH before them could type 'Black', choose a password and
# lock the owner out. Locking leaves nothing to type.
#
# The owner's first password — the one they give the first-run wizard for the
# panel's administrator — becomes this account's password too, through
# boneio-system's one-shot service-password-init. The wizard says so before it
# asks. After that it is passwd, which asks for the current one.
#
# The factory station is unaffected: in station mode the board boots the SD
# card, not the eMMC this image lands on, and the flasher sets the station
# password there with chpasswd, which replaces the hash and so clears the lock.
#
# BONEIO_USER_PASSWORD opts out, for an image that has to answer automation.
# Ansible, scp, a CI job and the black-tester station all authenticate without
# a human present, and a locked account stops every one of them dead: there
# is no password that will work. Until now the only
# way to keep a usable password was --no-cleanup, which also skips truncating
# the logs, resetting the machine-id and dropping the build-time sudo rule —
# so the choice was a sealed image nothing can log into, or a usable password
# on an image that was never sealed.
#
#   BONEIO_USER_PASSWORD='something' ./setup_boneio.sh
#
# Whatever is set here ships in the image and keeps working until somebody
# changes it. That is the thing expiry exists to prevent, so it is off by
# default and says so in the log when it is not.
if id "${BONEIO_USER}" >/dev/null 2>&1; then
    if [ -n "${BONEIO_USER_PASSWORD:-}" ]; then
        if echo "${BONEIO_USER}:${BONEIO_USER_PASSWORD}" | chpasswd 2>/dev/null; then
            # chpasswd on its own leaves the expiry date alone, and an earlier
            # run of this script may already have set it to 0. Both have to go —
            # and chpasswd replaces the hash, so it clears a lock as well.
            chage -d "$(( $(date +%s) / 86400 ))" "${BONEIO_USER}" 2>/dev/null || true
            log_warn "   ${BONEIO_USER} ships with a WORKING password (BONEIO_USER_PASSWORD)"
            log_warn "   It keeps working until someone changes it. Do not ship this image."
        else
            log_error "   Could not set the ${BONEIO_USER} password"
        fi
    else
        # Only lock when the boneIO in this image can unlock it. A lock is
        # opened by the wizard through boneio-system service-password-init; an
        # image built with an older BONEIO_VERSION has no such operation, and
        # locking it would leave the owner no password that ever works over
        # SSH. Such an image falls back to expiry and says so.
        if /usr/sbin/boneio-system --list-verbs 2>/dev/null | grep -q '"service-password-init"'; then
            passwd -l "${BONEIO_USER}" >/dev/null 2>&1 \
                && log_info "   ${BONEIO_USER} locked: no password login until the owner sets one" \
                || log_warn "   Could not lock the ${BONEIO_USER} password"
        else
            chage -d 0 "${BONEIO_USER}" 2>/dev/null || true
            log_warn "   boneIO ${BONEIO_VERSION} cannot set the SSH password from the wizard,"
            log_warn "   so ${BONEIO_USER} is only EXPIRED, not locked. Whoever logs in first"
            log_warn "   with the shipped password chooses the next one. Build with a newer"
            log_warn "   BONEIO_VERSION before shipping this image."
        fi
    fi
fi

# Clear bash history
history -c
rm -f /root/.bash_history
rm -f ${BONEIO_HOME}/.bash_history

echo ""
echo "================================================================================"
echo "  SETUP COMPLETE!"
echo "================================================================================"
echo ""
echo "System will halt in 5 seconds."
echo "After halt (all LEDs freeze/stop):"
echo "  1. Disconnect power / remove SD card from BBB"
echo "  2. On PC: sudo ./create_rootfs_img.sh /dev/sdX rootfs.img"
echo ""

sleep 5
sync
halt -f
