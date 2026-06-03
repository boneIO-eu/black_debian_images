#!/bin/bash
## BoneIO Black — Automated Image Builder
##
## Usage:
##   ./build_image_usb.sh <version> [--sd-device /dev/sdX] [--from-phase N]
##
## Example:
##   ./build_image_usb.sh 1.4.2
##   ./build_image_usb.sh 1.4.2 --sd-device /dev/sdb
##   ./build_image_usb.sh 1.4.2 --from-phase 5 --sd-device /dev/sdb  # resume
##
## This script automates the full image creation pipeline:
##   Phase 1: Wait for BBB on USB (192.168.7.2)
##   Phase 2: Create boneio user (if default beagle user exists)
##   Phase 3: Run setup_boneio.sh remotely via SSH
##   Phase 4: Wait for BBB shutdown
##   Phase 5: Create rootfs image from SD card (after reinserting into PC)
##   Phase 6: Generate all hardware variant images
##
## Requirements:
##   - sshpass (apt install sshpass)
##   - pishrink.sh in PATH (https://github.com/Drewsif/PiShrink)
##   - BeagleBone Black connected via USB
##   - Fresh Debian 13 on SD card (from beagleboard.org)

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

BBB_USB_IP="192.168.7.2"
BBB_DEFAULT_USER="beagle"
BBB_DEFAULT_PASS="temppwd"
BONEIO_USER="boneio"
BONEIO_PASS="Black"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
SETUP_SCRIPT_URL="https://raw.githubusercontent.com/boneIO-eu/black_debian_images/main/scripts/setup_boneio.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_INTERVAL=3       # seconds between connection attempts
SHUTDOWN_POLL=5        # seconds between shutdown checks

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_phase() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}\n"; }
log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}  ➜${NC} $1"; }

# ─── Argument parsing ────────────────────────────────────────────────────────

VERSION=""
SD_DEVICE=""
FROM_PHASE=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sd-device)
            SD_DEVICE="$2"
            shift 2
            ;;
        --from-phase)
            FROM_PHASE="$2"
            shift 2
            ;;
        --help|-h)
            head -25 "$0" | grep '^##' | sed 's/^## \?//'
            exit 0
            ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$1"
            else
                log_error "Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    log_error "Usage: $0 <version> [--sd-device /dev/sdX]"
    log_error "Example: $0 1.4.2"
    exit 1
fi

# ─── Preflight checks ───────────────────────────────────────────────────────

if ! command -v sshpass &>/dev/null; then
    log_error "sshpass is required. Install: sudo apt install sshpass"
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  BoneIO Black — Automated Image Builder             ║"
echo "║  Version: ${VERSION}                                        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

if [[ "${FROM_PHASE}" -gt 1 ]]; then
    log_info "Skipping to phase ${FROM_PHASE}..."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Wait for BBB on USB
# ═══════════════════════════════════════════════════════════════════════════════

if (( FROM_PHASE <= 1 )); then
log_phase "Phase 1/6: Waiting for BeagleBone on USB (${BBB_USB_IP})"
log_info "Connect BBB via USB cable and boot from SD card."
log_info "Press Ctrl+C to abort."

while ! ping -c 1 -W 1 "${BBB_USB_IP}" &>/dev/null; do
    echo -n "."
    sleep "${POLL_INTERVAL}"
done
echo ""
log_info "BBB detected at ${BBB_USB_IP}!"

# Wait a bit for SSH to be ready
log_step "Waiting for SSH to be ready..."
SSH_READY=false
for i in $(seq 1 30); do
    if sshpass -p "${BBB_DEFAULT_PASS}" ssh ${SSH_OPTS} "${BBB_DEFAULT_USER}@${BBB_USB_IP}" "echo ok" &>/dev/null; then
        SSH_READY=true
        break
    fi
    # Maybe boneio user already exists (sysconf.txt was used)
    if sshpass -p "${BONEIO_PASS}" ssh ${SSH_OPTS} "${BONEIO_USER}@${BBB_USB_IP}" "echo ok" &>/dev/null; then
        SSH_READY=true
        BBB_DEFAULT_USER="${BONEIO_USER}"
        BBB_DEFAULT_PASS="${BONEIO_PASS}"
        log_info "User '${BONEIO_USER}' already exists (sysconf.txt). Skipping user creation."
        break
    fi
    sleep 2
done

if ! $SSH_READY; then
    log_error "SSH not available after 60 seconds. Check BBB boot."
    exit 1
fi
log_info "SSH ready! Connected as '${BBB_DEFAULT_USER}'."
fi  # FROM_PHASE <= 1

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: Create boneio user
# ═══════════════════════════════════════════════════════════════════════════════

if (( FROM_PHASE <= 2 )); then
log_phase "Phase 2/6: Creating user '${BONEIO_USER}'"

if [[ "${BBB_DEFAULT_USER}" == "${BONEIO_USER}" ]]; then
    log_info "User '${BONEIO_USER}' already exists, skipping."
else
    log_step "Creating user '${BONEIO_USER}' with sudo privileges..."
    sshpass -p "${BBB_DEFAULT_PASS}" ssh ${SSH_OPTS} "${BBB_DEFAULT_USER}@${BBB_USB_IP}" "
        echo '${BBB_DEFAULT_PASS}' | sudo -S bash -c '
            adduser ${BONEIO_USER} --gecos \"\" --disabled-password
            echo \"${BONEIO_USER}:${BONEIO_PASS}\" | chpasswd
            usermod -aG sudo ${BONEIO_USER}
            # Allow passwordless sudo for setup script
            echo \"${BONEIO_USER} ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/boneio-setup
            chmod 0440 /etc/sudoers.d/boneio-setup
        '
    "
    log_info "User '${BONEIO_USER}' created."

    # Verify SSH as boneio
    log_step "Verifying SSH as '${BONEIO_USER}'..."
    if ! sshpass -p "${BONEIO_PASS}" ssh ${SSH_OPTS} "${BONEIO_USER}@${BBB_USB_IP}" "echo ok" &>/dev/null; then
        log_error "Cannot SSH as '${BONEIO_USER}'. Check user creation."
        exit 1
    fi
    log_info "SSH as '${BONEIO_USER}' verified."
fi
fi  # FROM_PHASE <= 2

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: Run setup_boneio.sh
# ═══════════════════════════════════════════════════════════════════════════════

if (( FROM_PHASE <= 3 )); then
log_phase "Phase 3/6: Running setup_boneio.sh on BBB"
log_info "This will take 5-15 minutes. Watch the output below."
log_warn "BBB will shutdown automatically when done."
echo ""

# Download script first, then run with sudo -S (password via stdin).
# curl-pipe-to-sudo doesn't work well with PTY and password prompts.
sshpass -p "${BONEIO_PASS}" ssh ${SSH_OPTS} "${BONEIO_USER}@${BBB_USB_IP}" \
    "curl -H 'Cache-Control: no-cache' -fsSL '${SETUP_SCRIPT_URL}' -o /tmp/setup_boneio.sh && chmod +x /tmp/setup_boneio.sh"

log_info "Setup script downloaded to BBB. Running..."

sshpass -p "${BONEIO_PASS}" ssh ${SSH_OPTS} "${BONEIO_USER}@${BBB_USB_IP}" \
    "echo '${BONEIO_PASS}' | sudo -S bash /tmp/setup_boneio.sh" \
    || true  # setup ends with poweroff which kills SSH

echo ""
log_info "Setup script finished (BBB is shutting down)."
fi  # FROM_PHASE <= 3

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: Wait for BBB shutdown
# ═══════════════════════════════════════════════════════════════════════════════

if (( FROM_PHASE <= 4 )); then
log_phase "Phase 4/6: Waiting for BBB to shutdown"

# BBB needs a moment to actually poweroff
sleep 5

SHUTDOWN_CONFIRMED=false
for i in $(seq 1 30); do
    if ! ping -c 1 -W 1 "${BBB_USB_IP}" &>/dev/null; then
        SHUTDOWN_CONFIRMED=true
        break
    fi
    echo -n "."
    sleep "${SHUTDOWN_POLL}"
done
echo ""

if $SHUTDOWN_CONFIRMED; then
    log_info "BBB has shutdown successfully."
else
    log_warn "BBB still reachable. It may need manual poweroff."
fi
fi  # FROM_PHASE <= 4

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5: Create rootfs image from SD card
# ═══════════════════════════════════════════════════════════════════════════════

log_phase "Phase 5/6: Create rootfs image from SD card"

if [[ -z "${SD_DEVICE}" ]]; then
    echo -e "${BOLD}Now:${NC}"
    echo "  1. Remove SD card from BBB"
    echo "  2. Insert SD card into THIS computer"
    echo ""
    read -rp "Press Enter when SD card is inserted... "
    echo ""

    # Auto-detect: look for removable devices in 16-128GB range (typical SD cards)
    SD_GUESS=""
    while IFS= read -r line; do
        dev_name=$(echo "$line" | awk '{print $1}')
        dev_size_bytes=$(echo "$line" | awk '{print $2}')
        dev_tran=$(echo "$line" | awk '{print $4}')
        # Skip if no size
        [[ -z "$dev_size_bytes" || "$dev_size_bytes" == "0" ]] && continue
        # Convert to GB
        dev_size_gb=$(( dev_size_bytes / 1073741824 ))
        # Match 16-128GB range, prefer USB/MMC transport
        if (( dev_size_gb >= 16 && dev_size_gb <= 128 )); then
            SD_GUESS="/dev/${dev_name}"
            break
        fi
    done < <(lsblk -bndo NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -v "loop\|sr\|ram")

    echo -e "${YELLOW}Available block devices:${NC}"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "loop\|sr\|ram" || true
    echo ""

    if [[ -n "${SD_GUESS}" ]]; then
        read -rp "Enter SD card device [${SD_GUESS}]: " SD_DEVICE
        SD_DEVICE="${SD_DEVICE:-${SD_GUESS}}"
    else
        read -rp "Enter SD card device (e.g., /dev/sdb): " SD_DEVICE
    fi
fi

if [[ ! -b "${SD_DEVICE}" ]]; then
    log_error "Device ${SD_DEVICE} not found. Check lsblk."
    exit 1
fi

# Safety check
echo ""
echo -e "${RED}${BOLD}WARNING: Will read from ${SD_DEVICE}${NC}"
lsblk "${SD_DEVICE}" 2>/dev/null || true
echo ""
read -rp "Is this correct? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_error "Aborted."
    exit 1
fi

ROOTFS_IMG="rootfs-v${VERSION}.img"
log_step "Creating ${ROOTFS_IMG} from ${SD_DEVICE}..."

if [[ -f "${SCRIPT_DIR}/create_rootfs_img.sh" ]]; then
    sudo bash "${SCRIPT_DIR}/create_rootfs_img.sh" "${SD_DEVICE}" "${ROOTFS_IMG}"
else
    log_error "create_rootfs_img.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

log_info "Rootfs image created: ${ROOTFS_IMG}"

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 6: Generate all variant images
# ═══════════════════════════════════════════════════════════════════════════════

log_phase "Phase 6/6: Generating hardware variant images"

if [[ -f "${SCRIPT_DIR}/generate_all_images.sh" ]]; then
    sudo bash "${SCRIPT_DIR}/generate_all_images.sh" "${ROOTFS_IMG}" "${VERSION}" --emmc-flasher
else
    log_error "generate_all_images.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅ Image build complete!                            ║"
echo "║  Version: v${VERSION}                                       ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Generated images:                                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
ls -lh boneio-black-v${VERSION}-*.img.xz 2>/dev/null || echo "  (images in current directory)"
echo ""
log_info "Upload these to GitHub Releases."
