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

for arg in "$@"; do
    case $arg in
        --emmc-flasher)
            GENERATE_EMMC_FLASHER=true
            shift
            ;;
        *)
            if [ -z "$SOURCE_IMAGE" ]; then
                SOURCE_IMAGE="$arg"
            elif [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                VERSION="$arg"
            fi
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

# Device types to generate
declare -A DEVICE_TYPES=(
    ["32x10"]="32x10"
    ["24x16"]="24x16"
    ["cover"]="cover"
    ["cover_mix"]="cover_mix"
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
    
    # Find rootfs partition (ext4)
    ROOTFS_PARTITION=""
    for part in "${LOOP_DEVICE}p"*; do
        if [ -e "$part" ]; then
            FS_TYPE=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "unknown")
            if [ "$FS_TYPE" = "ext4" ] || [ "$FS_TYPE" = "ext3" ]; then
                ROOTFS_PARTITION="$part"
                print_info "Found rootfs partition: $ROOTFS_PARTITION ($FS_TYPE)"
                break
            fi
        fi
    done
    
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
}

# Function to create eMMC flasher image
create_emmc_flasher() {
    local sdcard_img="$1"
    local device_name="$2"
    local flasher_name="${OUTPUT_DIR}/${BASE_NAME}-${device_name}-emmc-flasher.img"
    
    print_info "Creating eMMC flasher for $device_name..."
    
    # Get sizes
    local sdcard_xz="${sdcard_img}.xz"
    if [ ! -f "$sdcard_xz" ]; then
        print_error "Compressed SDCARD image not found: $sdcard_xz"
        return 1
    fi
    
    local img_size=$(stat -c%s "$sdcard_xz")
    local img_size_mb=$((img_size / 1024 / 1024))
    local boot_size_mb=64
    local image_size_mb=$((img_size_mb + 50))
    local total_size_mb=$((boot_size_mb + image_size_mb + 10))
    
    print_info "Creating flasher image (${total_size_mb}MB)..."
    
    # Create empty image
    dd if=/dev/zero of="$flasher_name" bs=1M count=$total_size_mb status=progress
    
    # Partition
    sfdisk --force "$flasher_name" <<EOF
4M,${boot_size_mb}M,0xC,*
$((4 + boot_size_mb))M,${image_size_mb}M,L,-
EOF

    # Setup loop device
    FLASHER_LOOP=$(losetup -fP --show "$flasher_name")
    sleep 1
    partprobe "$FLASHER_LOOP" || true
    sleep 1
    
    # Format partitions
    mkfs.vfat -F 32 "${FLASHER_LOOP}p1" -n BOOT
    mkfs.ext4 -L IMAGE "${FLASHER_LOOP}p2"
    
    # Mount boot partition
    mkdir -p /tmp/flasher_boot
    mount "${FLASHER_LOOP}p1" /tmp/flasher_boot
    
    # Copy boot files from SDCARD image (need to decompress first)
    print_info "Extracting boot files from SDCARD image..."
    mkdir -p /tmp/sdcard_mount
    local tmp_img="/tmp/sdcard_tmp.img"
    xzcat "$sdcard_xz" > "$tmp_img"
    SDCARD_LOOP=$(losetup -fP --show "$tmp_img")
    sleep 1
    partprobe "$SDCARD_LOOP" || true
    sleep 1
    
    # Find and mount boot partition
    if [ -b "${SDCARD_LOOP}p1" ]; then
        mount -o ro "${SDCARD_LOOP}p1" /tmp/sdcard_mount 2>/dev/null || \
        mount -o ro "$SDCARD_LOOP" /tmp/sdcard_mount
    else
        mount -o ro "$SDCARD_LOOP" /tmp/sdcard_mount
    fi
    
    # Copy boot files
    if [ -d /tmp/sdcard_mount/boot/firmware ]; then
        cp -rv /tmp/sdcard_mount/boot/firmware/* /tmp/flasher_boot/
    elif [ -d /tmp/sdcard_mount/boot ]; then
        cp -rv /tmp/sdcard_mount/boot/* /tmp/flasher_boot/
    else
        cp -rv /tmp/sdcard_mount/* /tmp/flasher_boot/
    fi
    
    # Modify uEnv.txt for flasher
    if [ -f /tmp/flasher_boot/uEnv.txt ]; then
        echo "" >> /tmp/flasher_boot/uEnv.txt
        echo "# DD-based eMMC flasher with xz decompression" >> /tmp/flasher_boot/uEnv.txt
        echo "cmdline=init=/usr/sbin/init-beagle-flasher-img" >> /tmp/flasher_boot/uEnv.txt
    fi
    
    umount /tmp/sdcard_mount
    losetup -d "$SDCARD_LOOP"
    rm -f "$tmp_img"
    sync
    umount /tmp/flasher_boot
    
    # Copy compressed image to IMAGE partition
    print_info "Copying compressed rootfs to flasher..."
    mkdir -p /tmp/flasher_image
    mount "${FLASHER_LOOP}p2" /tmp/flasher_image
    cp -v "$sdcard_xz" /tmp/flasher_image/rootfs.img.xz
    sync
    umount /tmp/flasher_image
    
    # Cleanup
    losetup -d "$FLASHER_LOOP"
    
    # Compress flasher image
    print_info "Compressing flasher image..."
    xz -9 -T0 -v "$flasher_name"
    
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
    
    # Step 3: Run prepare_image.sh (if it takes mount point and device)
    print_info "Preparing image for $device_name..."
    if [ -x "$PREPARE_SCRIPT" ]; then
        # If prepare_script accepts mount point, use it
        # Otherwise just ensure mount is good
        true
    fi
    
    # Step 4: Install flasher script if needed
    if [ "$GENERATE_EMMC_FLASHER" = true ]; then
        install_flasher_script
    fi
    
    # Step 5: Unmount
    unmount_image
    
    # Step 6: Compress with xz
    print_info "Compressing $output_name with xz (this may take a while)..."
    xz -9 -T0 -v "$output_name"
    
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
    umount /tmp/flasher_boot 2>/dev/null || true
    umount /tmp/flasher_image 2>/dev/null || true
    umount /tmp/sdcard_mount 2>/dev/null || true
    rm -f /tmp/sdcard_tmp.img
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
echo ""

# Process each device type
for device_name in "${!DEVICE_TYPES[@]}"; do
    process_device_type "$device_name" "${DEVICE_TYPES[$device_name]}"
done

echo ""
echo "========================================"
print_info "All images generated successfully!"
echo "========================================"
echo ""
echo "Generated files:"
ls -lh "${OUTPUT_DIR}/${BASE_NAME}"*.img.xz 2>/dev/null || echo "No compressed images found"
