#!/bin/bash
# Script to generate all BoneIO Black image variants from a source image
# Usage: ./generate_all_images.sh <source_image.img> [version] [--emmc-flasher]
#
# Options:
#   --emmc-flasher    Also generate eMMC flasher images for each variant
#
# Example: 
#   ./generate_all_images.sh rootfs.img 1.0.2
#   ./generate_all_images.sh rootfs.img 1.0.2 --emmc-flasher

set -e

# Parse arguments
SOURCE_IMAGE=""
VERSION="1.0.1"
GENERATE_EMMC_FLASHER=false
ONLY_DEVICE=""

while [ $# -gt 0 ]; do
    case $1 in
        --emmc-flasher)
            GENERATE_EMMC_FLASHER=true
            shift
            ;;
        --only)
            ONLY_DEVICE="$2"
            shift 2
            ;;
        *)
            if [ -z "$SOURCE_IMAGE" ]; then
                SOURCE_IMAGE="$1"
            elif [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                VERSION="$1"
            fi
            shift
            ;;
    esac
done

# Get the actual user who invoked sudo (if any)
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_UID="${SUDO_UID:-$(id -u)}"
ACTUAL_GID="${SUDO_GID:-$(id -g)}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Check if script is run with sudo/root privileges
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run with sudo privileges!"
    echo "Usage: sudo $0 <source_image.img> [version] [--emmc-flasher]"
    exit 1
fi

# Validate arguments
if [ -z "$SOURCE_IMAGE" ]; then
    print_error "Source image not provided!"
    echo "Usage: sudo $0 <source_image.img> [version] [--emmc-flasher]"
    echo ""
    echo "Options:"
    echo "  --emmc-flasher    Also generate eMMC flasher images"
    echo ""
    echo "Example: sudo $0 rootfs.img 1.0.2 --emmc-flasher"
    exit 1
fi

if [ ! -f "$SOURCE_IMAGE" ]; then
    print_error "Source image $SOURCE_IMAGE does not exist!"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE_SCRIPT="$SCRIPT_DIR/prepare_image.sh"
FLASHER_INIT="$SCRIPT_DIR/flasher/init-beagle-flasher-img"
OLED_SCRIPT="$SCRIPT_DIR/flasher/oled_msg.sh"
OLED_PYTHON="$SCRIPT_DIR/flasher/oled_msg.py"

if [ ! -f "$PREPARE_SCRIPT" ]; then
    print_error "prepare_image.sh not found in $SCRIPT_DIR"
    exit 1
fi

if [ "$GENERATE_EMMC_FLASHER" = true ] && [ ! -f "$FLASHER_INIT" ]; then
    print_error "init-beagle-flasher-img not found in $SCRIPT_DIR/flasher/"
    print_error "Required for --emmc-flasher option"
    exit 1
fi

# Mount point
MOUNT_POINT="/mnt/boneio_image"
mkdir -p "$MOUNT_POINT"

# Device types to generate (in order: 32x10 first)
DEVICE_TYPES=(
    "32x10"
    "24x16"
    "cover"
    "cover_mix"
)

# Output directory (same as source image)
OUTPUT_DIR="$(dirname "$(realpath "$SOURCE_IMAGE")")"

# Base name for images
BASE_NAME="boneio-black-v${VERSION}"

# Function to mount image
mount_image() {
    local img_file="$1"
    
    print_info "Setting up loop device for $img_file..."
    LOOP_DEVICE=$(losetup -fP --show "$img_file")
    
    if [ -z "$LOOP_DEVICE" ]; then
        print_error "Failed to create loop device!"
        return 1
    fi
    
    print_info "Loop device: $LOOP_DEVICE"
    
    # Wait for partitions to appear
    sleep 1
    partprobe "$LOOP_DEVICE" 2>/dev/null || true
    sleep 1
    
    # Find rootfs partition (ext4) — take LAST ext4 partition
    # BBB Debian images have small p2 (ext4) + main rootfs p3 (ext4)
    ROOTFS_PARTITION=""
    for part in "${LOOP_DEVICE}p"*; do
        if [ -e "$part" ]; then
            FS_TYPE=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "unknown")
            if [ "$FS_TYPE" = "ext4" ] || [ "$FS_TYPE" = "ext3" ]; then
                ROOTFS_PARTITION="$part"
                # Don't break — keep iterating to find the LAST (main) ext4 partition
            fi
        fi
    done
    if [ -n "$ROOTFS_PARTITION" ]; then
        print_info "Found rootfs partition: $ROOTFS_PARTITION"
    fi
    
    if [ -z "$ROOTFS_PARTITION" ]; then
        print_error "Could not find rootfs partition!"
        losetup -d "$LOOP_DEVICE"
        return 1
    fi
    
    # Mount rootfs
    print_info "Mounting rootfs..."
    mount "$ROOTFS_PARTITION" "$MOUNT_POINT"
    
    return 0
}

# Function to unmount image
unmount_image() {
    print_info "Unmounting image..."
    
    # Sync to ensure all writes are complete
    sync
    
    # Unmount boot if mounted
    umount "$MOUNT_POINT/boot" 2>/dev/null || true
    
    # Unmount rootfs
    umount "$MOUNT_POINT" 2>/dev/null || true
    
    # Detach loop device
    if [ -n "$LOOP_DEVICE" ]; then
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
    
    LOOP_DEVICE=""
}

# Function to copy flasher init script to image
install_flasher_script() {
    local dest="$MOUNT_POINT/usr/sbin/init-beagle-flasher-img"
    
    print_info "Installing flasher script..."
    cp "$FLASHER_INIT" "$dest"
    chmod +x "$dest"
    
    # Install OLED helper scripts (optional, for display feedback during flash)
    if [ -f "$OLED_SCRIPT" ]; then
        cp "$OLED_SCRIPT" "$MOUNT_POINT/usr/sbin/oled_msg.sh"
        chmod +x "$MOUNT_POINT/usr/sbin/oled_msg.sh"
        print_info "Installed OLED shell wrapper"
    fi
    if [ -f "$OLED_PYTHON" ]; then
        cp "$OLED_PYTHON" "$MOUNT_POINT/usr/sbin/oled_msg.py"
        chmod +x "$MOUNT_POINT/usr/sbin/oled_msg.py"
        print_info "Installed OLED Python renderer"
    fi
}

# Function to apply device-specific BoneIO config from example_config inside image
# Finds the config directory in /home/boneio/.cache/boneio_configs, repo configs/, or venv
# and copies the correct variant's YAML files and cache to /home/boneio/boneio/
apply_device_config() {
    local device_name="$1"
    local boneio_config_dir="$MOUNT_POINT/home/boneio/boneio"
    
    if [ ! -d "$boneio_config_dir" ]; then
        print_warning "BoneIO config dir not found: $boneio_config_dir"
        return 1
    fi
    
    # 1. Check repo configs/ directory (has latest YAMLs + pre-generated .cache.pkl)
    local example_dir=""
    if [ -d "$SCRIPT_DIR/../configs/$device_name" ]; then
        example_dir="$SCRIPT_DIR/../configs/$device_name"
    # 2. Check /home/boneio/.cache/boneio_configs inside the mounted image
    elif [ -d "$MOUNT_POINT/home/boneio/.cache/boneio_configs/$device_name" ]; then
        example_dir="$MOUNT_POINT/home/boneio/.cache/boneio_configs/$device_name"
    # 3. Fallback to venv example_config
    else
        for site_pkg in "$MOUNT_POINT"/home/boneio/boneio/venv/lib/python*/site-packages/boneio/example_config; do
            if [ -d "$site_pkg/$device_name" ]; then
                example_dir="$site_pkg/$device_name"
                break
            fi
        done
    fi
    
    if [ -z "$example_dir" ] || [ ! -d "$example_dir" ]; then
        print_error "Config not found for device '$device_name'!"
        return 1
    fi
    
    # Remove old YAML config files, caches and state (but keep venv, etc.)
    print_info "Removing old config YAMLs, caches and state from $boneio_config_dir..."
    rm -f "$boneio_config_dir"/*.yaml
    rm -f "$boneio_config_dir"/*.cache.pkl
    rm -f "$boneio_config_dir"/state.json
    rm -f "$boneio_config_dir"/__init__.py
    rm -rf "$boneio_config_dir"/__pycache__
    for subdir in 24x16 32x10 48x4 cover cover_mix different_configs tester; do
        rm -rf "$boneio_config_dir/$subdir"
    done
    
    # Copy new config files and pre-generated cache for this variant
    print_info "Applying $device_name config from $example_dir..."
    cp -v "$example_dir"/*.yaml "$boneio_config_dir/"
    cp -v "$example_dir"/*.cache.pkl "$boneio_config_dir/" 2>/dev/null || true
    
    # Fix ownership (boneio user, UID/GID 1000 typically)
    chown -R 1000:1000 "$boneio_config_dir"/* 2>/dev/null || true
    
    print_info "Device config applied: $device_name"
    
    # Show what was copied
    ls -la "$boneio_config_dir"/*.yaml "$boneio_config_dir"/*.cache.pkl 2>/dev/null || ls -la "$boneio_config_dir"/*.yaml 2>/dev/null
}

# Function to create eMMC flasher image (dd-to-SD-card ready)
# Works like create_flasher_sd.sh but outputs a .img file instead of writing
# to a physical SD card. The image contains:
#   - Bootable Debian rootfs (from the sdcard image)
#   - /boneio-emmc.img embedded copy (image to flash to eMMC)
#   - Flasher init script + OLED helper scripts
#   - uEnv.txt with cmdline=init=/usr/sbin/init-beagle-flasher-img
create_emmc_flasher() {
    local sdcard_img="$1"
    local device_name="$2"
    local flasher_name="${OUTPUT_DIR}/${BASE_NAME}-${device_name}-emmc-flasher.img"
    
    print_info "Creating eMMC flasher for $device_name..."
    
    # We need the uncompressed sdcard image. Since process_device_type already
    # compressed it, we need to decompress first.
    local sdcard_xz="${sdcard_img}.xz"
    if [ ! -f "$sdcard_xz" ]; then
        print_error "Compressed SDCARD image not found: $sdcard_xz"
        return 1
    fi
    
    # Decompress sdcard image to a temp file (this is the eMMC payload)
    local emmc_payload="/tmp/boneio_emmc_payload.img"
    print_info "Decompressing sdcard image for eMMC payload..."
    xzcat "$sdcard_xz" > "$emmc_payload"
    
    local payload_size=$(stat -c%s "$emmc_payload")
    local payload_size_mb=$((payload_size / 1024 / 1024))
    
    # Flasher image needs: rootfs + embedded copy of eMMC image + overhead
    # Total = original image + embedded image + ~100MB headroom
    local total_size_mb=$((payload_size_mb * 2 + 200))
    
    print_info "Creating flasher image (${total_size_mb}MB = rootfs + embedded eMMC image)..."
    
    # Start by copying the rootfs image as the base of the flasher
    cp "$emmc_payload" "$flasher_name"
    
    # Extend the image file BEFORE setting up loop device
    # so the kernel sees the full size from the start
    truncate -s ${total_size_mb}M "$flasher_name"
    
    # Setup loop device (after truncate, so it sees full size)
    FLASHER_LOOP=$(losetup -fP --show "$flasher_name")
    sleep 1
    partprobe "$FLASHER_LOOP" || true
    sleep 1
    
    print_info "Loop device: $FLASHER_LOOP, image size: ${total_size_mb}MB"
    
    # Find ext4 rootfs partition
    local rootfs_part=""
    local part_num=""
    for i in 1 2 3; do
        local part="${FLASHER_LOOP}p${i}"
        if [ -b "$part" ]; then
            local fs_type=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "unknown")
            if [ "$fs_type" = "ext4" ] || [ "$fs_type" = "ext3" ]; then
                rootfs_part="$part"
                part_num="$i"
                # Don't break — take the LAST ext4 (main rootfs, typically p3)
            fi
        fi
    done
    
    if [ -z "$rootfs_part" ]; then
        print_error "Could not find rootfs partition in flasher image!"
        losetup -d "$FLASHER_LOOP"
        rm -f "$flasher_name"
        rm -f "$emmc_payload"
        return 1
    fi
    
    # Expand partition to fill the image
    print_info "Expanding partition $part_num on $FLASHER_LOOP..."
    if command -v growpart &> /dev/null; then
        growpart -v "$FLASHER_LOOP" "$part_num" || {
            print_warning "growpart failed, trying sfdisk..."
            echo ", +" | sfdisk -N "$part_num" "$FLASHER_LOOP" --force 2>/dev/null || true
        }
    else
        echo ", +" | sfdisk -N "$part_num" "$FLASHER_LOOP" --force 2>/dev/null || true
    fi
    partprobe "$FLASHER_LOOP" || true
    sleep 1
    
    # Verify partition was expanded
    local new_part_size=$(blockdev --getsize64 "$rootfs_part" 2>/dev/null || echo 0)
    local new_part_size_mb=$((new_part_size / 1024 / 1024))
    print_info "Partition size after expansion: ${new_part_size_mb}MB"
    
    # Resize filesystem
    e2fsck -f -y "$rootfs_part" 2>/dev/null || true
    resize2fs "$rootfs_part"
    
    # Mount rootfs — temporarily override MOUNT_POINT for install_flasher_script
    local saved_mount_point="$MOUNT_POINT"
    MOUNT_POINT="/tmp/flasher_rootfs"
    mkdir -p "$MOUNT_POINT"
    mount -o rw "$rootfs_part" "$MOUNT_POINT"
    
    # Disable cmdline flasher in uEnv.txt BEFORE embedding the image
    # (the embedded image boots normally from eMMC, without the flasher)
    local uenv_file="$MOUNT_POINT/boot/uEnv.txt"
    if [ -f "$uenv_file" ]; then
        sed -i 's/^cmdline=init=\/usr\/sbin\/init-beagle-flasher/#cmdline=init=\/usr\/sbin\/init-beagle-flasher/' "$uenv_file"
        print_info "Disabled cmdline flasher in rootfs uEnv.txt"
    fi
    
    # Copy the eMMC payload into the rootfs
    print_info "Embedding eMMC image as /boneio-emmc.img (${payload_size_mb}MB, this takes a while)..."
    cp "$emmc_payload" "$MOUNT_POINT/boneio-emmc.img"
    rm -f "$emmc_payload"
    
    # Install flasher script + OLED helpers (uses $MOUNT_POINT)
    install_flasher_script

    # Apply tester config + cache to the SD card's own rootfs (used in station mode)
    apply_device_config "tester"

    # Pre-generate SSH host keys on the PC for the flasher SD card (takes 0.01s on PC)
    # and disable bbbio-set-sysconf so it boots into station mode instantly with zero delay.
    ssh-keygen -A -f "$MOUNT_POINT" 2>/dev/null || true
    rm -f "$MOUNT_POINT/etc/bbb.io/ssh_regenerate" 2>/dev/null || true
    rm -f "$MOUNT_POINT/etc/systemd/system/multi-user.target.wants/bbbio-set-sysconf.service" 2>/dev/null || true
    rm -f "$MOUNT_POINT/lib/systemd/system/multi-user.target.wants/bbbio-set-sysconf.service" 2>/dev/null || true

    # NOW enable cmdline flasher on the SD card's own uEnv.txt
    if [ -f "$uenv_file" ]; then
        echo "" >> "$uenv_file"
        echo "# DD-based eMMC flasher (active only on SD card)" >> "$uenv_file"
        echo "cmdline=init=/usr/sbin/init-beagle-flasher-img net.ifnames=0" >> "$uenv_file"
        print_info "Enabled cmdline flasher in flasher uEnv.txt"
    fi
    
    sync
    umount "$MOUNT_POINT"
    MOUNT_POINT="$saved_mount_point"
    losetup -d "$FLASHER_LOOP"
    
    # Compress flasher image
    print_info "Compressing flasher image with xz..."
    xz -9f -T0 -v "$flasher_name"
    
    # Change ownership
    if [ -n "$ACTUAL_UID" ] && [ -n "$ACTUAL_GID" ]; then
        chown "$ACTUAL_UID:$ACTUAL_GID" "${flasher_name}.xz"
    fi
    
    print_info "Created: ${flasher_name}.xz"
}

# Function to process one device type
process_device_type() {
    local device_name="$1"
    local device_config="$2"
    
    local output_name="${OUTPUT_DIR}/${BASE_NAME}-${device_name}-sdcard.img"
    
    echo ""
    echo "========================================"
    print_step "Processing: $device_name"
    echo "========================================"
    
    # Step 1: Copy source image
    print_info "Copying source image to $output_name..."
    cp "$SOURCE_IMAGE" "$output_name"
    
    # Step 2: Mount the image
    if ! mount_image "$output_name"; then
        print_error "Failed to mount image for $device_name"
        rm -f "$output_name"
        return 1
    fi
    
    # Step 3: Apply device-specific BoneIO configuration
    print_info "Applying device config for $device_name..."
    if ! apply_device_config "$device_name"; then
        print_error "Failed to apply config for $device_name"
        unmount_image
        rm -f "$output_name"
        return 1
    fi
    
    # Step 4: Install flasher script if needed
    if [ "$GENERATE_EMMC_FLASHER" = true ]; then
        install_flasher_script
    fi
    
    # Step 5: Unmount
    unmount_image
    
    # Step 6: Compress with xz
    print_info "Compressing $output_name with xz (this may take a while)..."
    xz -9f -T0 -v "$output_name"
    
    # Step 7: Change ownership to actual user
    if [ -n "$ACTUAL_UID" ] && [ -n "$ACTUAL_GID" ]; then
        chown "$ACTUAL_UID:$ACTUAL_GID" "${output_name}.xz"
        print_info "Changed ownership of ${output_name}.xz to $ACTUAL_USER"
    fi
    
    print_info "Created: ${output_name}.xz"
    
    # Step 8: Create eMMC flasher if requested
    if [ "$GENERATE_EMMC_FLASHER" = true ]; then
        create_emmc_flasher "$output_name" "$device_name"
    fi
    
    return 0
}

# Cleanup function
cleanup() {
    print_warning "Cleaning up..."
    unmount_image
    umount /tmp/flasher_rootfs 2>/dev/null || true
    rm -f /tmp/boneio_emmc_payload.img
}

# Set trap for cleanup on exit
trap cleanup EXIT

# Main execution
echo ""
echo "========================================"
echo "  BoneIO Black Image Generator v2.0"
echo "========================================"
echo "Source image:      $SOURCE_IMAGE"
echo "Version:           $VERSION"
echo "Output directory:  $OUTPUT_DIR"
echo "Generate flasher:  $GENERATE_EMMC_FLASHER"
if [ -n "$ONLY_DEVICE" ]; then
    echo "Only device:       $ONLY_DEVICE"
fi
echo ""

# Auto-refresh config caches on host PC if app_black is available
APP_BLACK_DIR="$(realpath "$SCRIPT_DIR/../../app_black" 2>/dev/null || echo "")"
if command -v uv >/dev/null 2>&1 && [ -n "$APP_BLACK_DIR" ] && [ -d "$APP_BLACK_DIR" ]; then
    print_info "Refreshing config caches with uv and app_black..."
    (
        cd "$APP_BLACK_DIR"
        uv run python -c "
import os, sys
sys.path.insert(0, os.getcwd())
import boneio.core.config.yaml_util as y

base_dir = '$SCRIPT_DIR/../configs'
for variant in ['32x10', '24x16', 'cover', 'cover_mix', 'tester']:
    cfg = os.path.join(base_dir, variant, 'config.yaml')
    if os.path.isfile(cfg):
        try:
            y.load_config_from_file(cfg)
        except Exception:
            pass
" 2>/dev/null || true
    )
fi

# Process each device type in defined order (32x10 first)
for device_name in "${DEVICE_TYPES[@]}"; do
    # Skip devices not matching --only filter
    if [ -n "$ONLY_DEVICE" ] && [ "$device_name" != "$ONLY_DEVICE" ]; then
        continue
    fi
    process_device_type "$device_name" "$device_name"
done

echo ""
echo "========================================"
print_info "All images generated successfully!"
echo "========================================"
echo ""
echo "Generated files:"
ls -lh "${OUTPUT_DIR}/${BASE_NAME}"*.img.xz 2>/dev/null || echo "No compressed images found"
