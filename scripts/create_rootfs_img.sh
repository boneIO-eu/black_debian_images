#!/bin/bash
## Creates rootfs.img from SD card on PC using dd + pishrink
## Usage: sudo ./create_rootfs_img.sh /dev/sdX [output_file]
## Example: sudo ./create_rootfs_img.sh /dev/sdb ./rootfs.img
##
## Requires: pishrink.sh (https://github.com/Drewsif/PiShrink)

set -e

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with sudo privileges!"
   echo "Usage: sudo $0 /dev/sdX [output_file]"
   exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: sudo $0 <sd_card_device> [output_file]"
    echo "Example: sudo $0 /dev/sdb ./rootfs.img"
    exit 1
fi

SD_DEVICE="$1"
OUTPUT_FILE="${2:-./rootfs.img}"

# Validate SD device
if [ ! -b "${SD_DEVICE}" ]; then
    echo "ERROR: ${SD_DEVICE} is not a block device"
    exit 1
fi

# Safety check
if [[ "${SD_DEVICE}" == "/dev/sda" ]]; then
    echo "ERROR: Refusing to read from /dev/sda (likely system disk)"
    exit 1
fi

# Check pishrink is available
if ! command -v pishrink.sh &> /dev/null; then
    echo "ERROR: pishrink.sh not found in PATH"
    echo "Install from: https://github.com/Drewsif/PiShrink"
    echo "  wget https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh"
    echo "  chmod +x pishrink.sh"
    echo "  sudo mv pishrink.sh /usr/local/bin/"
    exit 1
fi

# Get SD card size
SD_SIZE=$(blockdev --getsize64 ${SD_DEVICE})
SD_SIZE_MB=$((SD_SIZE / 1024 / 1024))

echo "================================================================================"
echo "Creating rootfs.img from SD card (dd + pishrink)"
echo "================================================================================"
echo "SD Card:     ${SD_DEVICE}"
echo "SD Size:     ${SD_SIZE_MB} MB"
echo "Output:      ${OUTPUT_FILE}"
echo "================================================================================"
echo ""

# Unmount any mounted partitions
echo "--- Step 1/3: Unmounting SD card partitions ---"
umount ${SD_DEVICE}* 2>/dev/null || true

echo ""
echo "--- Step 2/3: Creating image with dd ---"
echo "This will take a while..."
dd if=${SD_DEVICE} of=${OUTPUT_FILE} bs=4M status=progress
sync

echo ""
echo "--- Step 3/3: Shrinking image with pishrink ---"
pishrink.sh -s ${OUTPUT_FILE}

FINAL_SIZE=$(stat -c%s ${OUTPUT_FILE})
FINAL_SIZE_MB=$((FINAL_SIZE / 1024 / 1024))

echo ""
echo "================================================================================"
echo "SUCCESS! Image created: ${OUTPUT_FILE}"
echo "Original SD size: ${SD_SIZE_MB} MB"
echo "Final image size: ${FINAL_SIZE_MB} MB"
echo ""
echo "Next step:"
echo "  sudo ./create_flasher_sd.sh /dev/sdX ${OUTPUT_FILE}"
echo "================================================================================"
