#!/bin/bash
## Creates SD card with bootable flasher and rootfs.img.xz for dd-based flashing
## Usage: sudo ./create_flasher_sd.sh /dev/sdX /path/to/rootfs.img[.xz]
##
## Supports both compressed (.xz) and uncompressed (.img) images.
## If input is uncompressed, it will be compressed before copying.

set -e

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with sudo privileges!"
   echo "Usage: sudo $0 /dev/sdX /path/to/rootfs.img[.xz]"
   exit 1
fi

if [ $# -lt 2 ]; then
    echo "Usage: sudo $0 <sd_card_device> <rootfs_image>"
    echo "Example: sudo $0 /dev/sdb ./boneio-rootfs.img.xz"
    echo ""
    echo "Supports both .img and .img.xz files."
    exit 1
fi

SD_DEVICE="$1"
ROOTFS_IMG="$2"

# Validate inputs
if [ ! -b "${SD_DEVICE}" ]; then
    echo "ERROR: ${SD_DEVICE} is not a block device"
    exit 1
fi

if [ ! -f "${ROOTFS_IMG}" ]; then
    echo "ERROR: ${ROOTFS_IMG} not found"
    exit 1
fi

# Safety check - don't allow /dev/sda
if [[ "${SD_DEVICE}" == "/dev/sda" ]]; then
    echo "ERROR: Refusing to write to /dev/sda (likely system disk)"
    exit 1
fi

# Detect if image is compressed
IS_COMPRESSED=false
if [[ "${ROOTFS_IMG}" == *.xz ]]; then
    IS_COMPRESSED=true
fi

IMG_SIZE=$(stat -c%s "${ROOTFS_IMG}")
IMG_SIZE_MB=$((IMG_SIZE / 1024 / 1024))

echo "================================================================================"
echo "SD Card Flasher Creator (v2.0 - xz support)"
echo "================================================================================"
echo "SD Card:     ${SD_DEVICE}"
echo "Image:       ${ROOTFS_IMG}"
echo "Image size:  ${IMG_SIZE_MB} MB"
echo "Compressed:  ${IS_COMPRESSED}"
echo "================================================================================"
echo ""
echo "WARNING: This will ERASE ALL DATA on ${SD_DEVICE}!"
echo ""
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "--- Step 1/5: Unmounting existing partitions ---"
umount ${SD_DEVICE}* 2>/dev/null || true

echo "--- Step 2/5: Partitioning SD card ---"
# Calculate partition sizes
BOOT_START_MB=4
BOOT_SIZE_MB=64
IMAGE_START_MB=$((BOOT_START_MB + BOOT_SIZE_MB))
# Image partition needs to fit the IMG file + some margin
IMAGE_SIZE_MB=$((IMG_SIZE_MB + 50))

echo "Boot partition:  ${BOOT_START_MB}MB - $((BOOT_START_MB + BOOT_SIZE_MB))MB"
echo "Image partition: ${IMAGE_START_MB}MB - $((IMAGE_START_MB + IMAGE_SIZE_MB))MB"

# Wipe and partition
dd if=/dev/zero of=${SD_DEVICE} bs=1M count=10 status=progress
sync

sfdisk --force --wipe-partitions always ${SD_DEVICE} <<EOF
${BOOT_START_MB}M,${BOOT_SIZE_MB}M,0xC,*
${IMAGE_START_MB}M,${IMAGE_SIZE_MB}M,L,-
EOF

sync
partprobe ${SD_DEVICE} || true
sleep 2

# Detect partition naming (sdb1 vs sdb p1)
if [ -b "${SD_DEVICE}1" ]; then
    PART1="${SD_DEVICE}1"
    PART2="${SD_DEVICE}2"
elif [ -b "${SD_DEVICE}p1" ]; then
    PART1="${SD_DEVICE}p1"
    PART2="${SD_DEVICE}p2"
else
    echo "ERROR: Cannot find partitions"
    exit 1
fi

echo "--- Step 3/5: Formatting partitions ---"
mkfs.vfat -F 32 ${PART1} -n BOOT
mkfs.ext4 -L IMAGE ${PART2}

echo "--- Step 4/5: Copying boot files ---"
mkdir -p /tmp/sd_boot
mount ${PART1} /tmp/sd_boot

# For compressed images, we need to decompress to mount
# For uncompressed, mount directly
mkdir -p /tmp/img_mount

if [ "${IS_COMPRESSED}" = true ]; then
    echo "Decompressing image to temp location for boot file extraction..."
    TMP_IMG="/tmp/rootfs_tmp.img"
    xzcat "${ROOTFS_IMG}" > "${TMP_IMG}"
    LOOP_DEV=$(losetup -fP --show "${TMP_IMG}")
else
    LOOP_DEV=$(losetup -fP --show "${ROOTFS_IMG}")
fi
sleep 1

# Try to find boot partition in image
if [ -b "${LOOP_DEV}p1" ]; then
    mount -o ro ${LOOP_DEV}p1 /tmp/img_mount 2>/dev/null || mount -o ro ${LOOP_DEV} /tmp/img_mount
else
    mount -o ro ${LOOP_DEV} /tmp/img_mount
fi

# Copy boot files
if [ -d /tmp/img_mount/boot/firmware ]; then
    cp -rv /tmp/img_mount/boot/firmware/* /tmp/sd_boot/
elif [ -d /tmp/img_mount/boot ]; then
    cp -rv /tmp/img_mount/boot/* /tmp/sd_boot/
else
    cp -rv /tmp/img_mount/* /tmp/sd_boot/
fi

# Modify uEnv.txt to use flasher init
if [ -f /tmp/sd_boot/uEnv.txt ]; then
    echo "" >> /tmp/sd_boot/uEnv.txt
    echo "# DD-based flasher with xz decompression" >> /tmp/sd_boot/uEnv.txt
    echo "cmdline=init=/usr/sbin/init-beagle-flasher-img" >> /tmp/sd_boot/uEnv.txt
fi

umount /tmp/img_mount
losetup -d ${LOOP_DEV}
sync
umount /tmp/sd_boot

# Clean up temp image if we created one
if [ "${IS_COMPRESSED}" = true ] && [ -f "${TMP_IMG}" ]; then
    rm -f "${TMP_IMG}"
fi

echo "--- Step 5/5: Copying rootfs image ---"
mkdir -p /tmp/sd_image
mount ${PART2} /tmp/sd_image

if [ "${IS_COMPRESSED}" = true ]; then
    # Copy compressed image directly
    echo "Copying compressed ${ROOTFS_IMG} to SD card..."
    cp -v "${ROOTFS_IMG}" /tmp/sd_image/rootfs.img.xz
else
    # Compress and copy
    echo "Compressing and copying ${ROOTFS_IMG} to SD card..."
    echo "This may take several minutes..."
    xz -c -9 -T0 "${ROOTFS_IMG}" > /tmp/sd_image/rootfs.img.xz
fi
sync

echo "Verifying..."
ls -lh /tmp/sd_image/

umount /tmp/sd_image
sync

echo ""
echo "================================================================================"
echo "SUCCESS! SD card flasher created."
echo ""
echo "To flash a BeagleBone:"
echo "  1. Insert SD card into BeagleBone"
echo "  2. Hold boot button and power on"
echo "  3. Wait for LEDs to indicate completion (all 4 LEDs on, ~4-6 minutes)"
echo "  4. Remove SD card and power on to boot from eMMC"
echo "================================================================================"

