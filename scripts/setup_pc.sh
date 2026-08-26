#!/bin/bash
# Installs/checks all dependencies needed on the PC (build host) to run the
# other scripts in this repo: generate_all_images.sh, create_rootfs_img.sh,
# create_flasher_sd.sh, build_image_usb.sh.
#
# This is NOT for the BeagleBone Black itself — that's scripts/setup_boneio.sh.
#
# Usage: sudo ./scripts/setup_pc.sh
#
# Installs:
#   - util-linux, parted   (losetup, partprobe, blkid, sfdisk, parted)
#   - cloud-guest-utils     (growpart)
#   - e2fsprogs             (e2fsck, resize2fs)
#   - xz-utils              (xz, xzcat)
#   - curl, ca-certificates (needed to fetch uv / pishrink.sh)
#   - uv                    (astral.sh installer, per-user, optional but recommended)
#   - pishrink.sh           (github.com/Drewsif/PiShrink, installed to /usr/local/bin)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run with sudo privileges!"
    echo "Usage: sudo $0"
    exit 1
fi

# Get the actual user who invoked sudo, so uv is installed for them, not root
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

if ! command -v apt-get &>/dev/null; then
    print_error "This script only supports apt-based systems (Ubuntu/Debian)."
    print_error "Install manually: util-linux parted cloud-guest-utils e2fsprogs xz-utils curl ca-certificates, plus uv and pishrink.sh"
    exit 1
fi

print_info "Updating package lists..."
apt-get update -qq

print_info "Installing system packages (util-linux, parted, growpart, e2fsprogs, xz-utils, curl)..."
apt-get install -y \
    util-linux \
    parted \
    cloud-guest-utils \
    e2fsprogs \
    xz-utils \
    curl \
    ca-certificates

# uv — installed per-user (not as root), used by generate_all_images.sh to
# auto-refresh the boneio config caches from a sibling app_black checkout.
if command -v -- sudo -u "$ACTUAL_USER" uv &>/dev/null || [ -x "$ACTUAL_HOME/.local/bin/uv" ]; then
    print_info "uv already installed for $ACTUAL_USER, skipping."
else
    print_info "Installing uv for $ACTUAL_USER..."
    sudo -u "$ACTUAL_USER" sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' || \
        print_warning "uv install failed — config-cache auto-refresh in generate_all_images.sh will be skipped, not fatal."
fi

# pishrink.sh — used as a fallback by create_rootfs_img.sh if partition
# shrink fails. Installed system-wide so any user can run it via sudo.
PISHRINK_PATH="/usr/local/bin/pishrink.sh"
if [ -x "$PISHRINK_PATH" ]; then
    print_info "pishrink.sh already installed at $PISHRINK_PATH, skipping."
else
    print_info "Downloading pishrink.sh to $PISHRINK_PATH..."
    curl -fsSL -o "$PISHRINK_PATH" https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh
    chmod +x "$PISHRINK_PATH"
fi

echo ""
print_info "PC setup complete. Checking tools..."
for tool in losetup partprobe blkid sfdisk parted growpart e2fsck resize2fs xz xzcat pishrink.sh; do
    if command -v "$tool" &>/dev/null; then
        echo "  [OK] $tool"
    else
        print_warning "  [MISSING] $tool"
    fi
done
if sudo -u "$ACTUAL_USER" command -v uv &>/dev/null || [ -x "$ACTUAL_HOME/.local/bin/uv" ]; then
    echo "  [OK] uv"
else
    print_warning "  [MISSING] uv (optional — only needed for config-cache auto-refresh)"
fi

echo ""
print_info "Note: generate_all_images.sh looks for a sibling 'app_black' checkout"
print_info "(i.e. ../app_black relative to this repo) to auto-refresh config caches."
print_info "This is optional — clone it next to this repo if you have access."
