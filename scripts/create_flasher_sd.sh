#!/bin/bash
## Creates flasher SD card from a source rootfs image
## The flasher boots into a Debian system and uses dd to flash eMMC
##
## Usage: sudo ./create_flasher_sd.sh /dev/sdX /path/to/rootfs.img
##
## Structure:
##   - Writes full rootfs.img to SD card (bootable Debian)
##   - Adds /boneio-emmc.img copy inside the rootfs
##   - Modifies /boot/uEnv.txt to use flasher init
##   - On boot: flasher reads /boneio-emmc.img and dd's it to eMMC

set -e

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with sudo privileges!"
   echo "Usage: sudo $0 /dev/sdX /path/to/rootfs.img"
   exit 1
fi

if [ $# -lt 2 ]; then
    echo "Usage: sudo $0 <sd_card_device> <rootfs_image>"
    echo "Example: sudo $0 /dev/sdb ./boneio-rootfs.img"
    echo ""
    echo "This creates a flasher SD card that will dd the image to eMMC on boot."
    exit 1
fi

SD_DEVICE="$1"
ROOTFS_IMG="$2"

# Get script directory for flasher script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLASHER_SCRIPT="$SCRIPT_DIR/flasher/init-beagle-flasher-img"
OLED_SCRIPT="$SCRIPT_DIR/flasher/oled_msg.sh"
OLED_PYTHON_SCRIPT="$SCRIPT_DIR/flasher/oled_msg.py"
OLED_BOOT_SPLASH="$SCRIPT_DIR/flasher/oled_boot_splash.py"
OLED_BOOT_SPLASH_SH="$SCRIPT_DIR/flasher/oled_boot_splash.sh"

# Validate inputs
if [ ! -b "${SD_DEVICE}" ]; then
    echo "ERROR: ${SD_DEVICE} is not a block device"
    exit 1
fi

if [ ! -f "${ROOTFS_IMG}" ]; then
    echo "ERROR: ${ROOTFS_IMG} not found"
    exit 1
fi

if [ ! -f "${FLASHER_SCRIPT}" ]; then
    echo "ERROR: Flasher script not found at ${FLASHER_SCRIPT}"
    exit 1
fi

# Safety check - don't allow /dev/sda
if [[ "${SD_DEVICE}" == "/dev/sda" ]]; then
    echo "ERROR: Refusing to write to /dev/sda (likely system disk)"
    exit 1
fi

IMG_SIZE=$(stat -c%s "${ROOTFS_IMG}")
IMG_SIZE_MB=$((IMG_SIZE / 1024 / 1024))

SD_SIZE=$(blockdev --getsize64 "${SD_DEVICE}")
SD_SIZE_MB=$((SD_SIZE / 1024 / 1024))

echo "================================================================================"
echo "SD Card Flasher Creator (v3.1)"
echo "================================================================================"
echo "SD Card:     ${SD_DEVICE} (${SD_SIZE_MB}MB)"
echo "Image:       ${ROOTFS_IMG}"
echo "Flasher:     ${FLASHER_SCRIPT}"
echo "================================================================================"
echo ""
echo "This will:"
echo "  1. Write the rootfs image to SD card"
echo "  2. Add a copy as /boneio-emmc.img inside the rootfs"
echo "  3. Install flasher script and modify uEnv.txt"
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
# Unmount all partitions (both /dev/sdb1 and /dev/sdbp1 style)
for part in ${SD_DEVICE}* ${SD_DEVICE}p*; do
    if mountpoint -q "$part" 2>/dev/null || mount | grep -q "^$part "; then
        echo "Unmounting $part..."
        umount "$part" 2>/dev/null || true
    fi
done
sync
sleep 1

echo ""
echo "--- Step 2/5: Writing base image to SD card ---"
echo "Writing image..."
dd if="${ROOTFS_IMG}" of="${SD_DEVICE}" bs=4M status=progress
sync
partprobe "${SD_DEVICE}" || true
sleep 2

echo ""
echo "--- Step 3/5: Mounting rootfs ---"
# Detect partition naming
if [ -b "${SD_DEVICE}p1" ]; then
    ROOTFS_PART="${SD_DEVICE}p1"
elif [ -b "${SD_DEVICE}1" ]; then
    ROOTFS_PART="${SD_DEVICE}1"
else
    echo "ERROR: Cannot find rootfs partition"
    exit 1
fi

# Find ext4 partition (rootfs)
for i in 1 2 3; do
    if [ -b "${SD_DEVICE}${i}" ]; then
        PART="${SD_DEVICE}${i}"
    elif [ -b "${SD_DEVICE}p${i}" ]; then
        PART="${SD_DEVICE}p${i}"
    else
        continue
    fi
    
    FS_TYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || echo "unknown")
    if [ "$FS_TYPE" = "ext4" ]; then
        ROOTFS_PART="$PART"
        PART_NUM="$i"
        echo "Found rootfs partition: $ROOTFS_PART"
        break
    fi
done

# Expand partition to fill SD card (pishrink makes it small)
echo "Expanding partition to fill SD card..."

# Use growpart if available, otherwise use parted
if command -v growpart &> /dev/null; then
    growpart "${SD_DEVICE}" "${PART_NUM}" || true
else
    # Force kernel to re-read partition table first
    partprobe "${SD_DEVICE}" 2>/dev/null || true
    sleep 1
    
    # Get partition start
    PART_START=$(sfdisk -l "${SD_DEVICE}" | grep "${ROOTFS_PART}" | awk '{print $2}')
    if [ -n "$PART_START" ]; then
        # Use sfdisk to resize (non-interactive)
        echo ", +" | sfdisk -N "${PART_NUM}" "${SD_DEVICE}" --force 2>/dev/null || true
    fi
fi

partprobe "${SD_DEVICE}" || true
sleep 1

# Resize filesystem
echo "Resizing filesystem..."
e2fsck -f -y "${ROOTFS_PART}" 2>/dev/null || true
resize2fs "${ROOTFS_PART}"

mkdir -p /tmp/flasher_rootfs
mount -o rw "${ROOTFS_PART}" /tmp/flasher_rootfs

echo ""
echo "--- Step 4/5: Adding boneio-emmc.img and flasher script ---"

# Ensure cmdline flasher is disabled in the rootfs uEnv.txt BEFORE copying
# the image. The source image must have cmdline disabled so that eMMC boots
# normally after flashing (dd copies raw blocks, not files).
UENV_FILE="/tmp/flasher_rootfs/boot/uEnv.txt"
if [ -f "$UENV_FILE" ]; then
    sed -i 's/^cmdline=init=\/usr\/sbin\/init-beagle-flasher/#cmdline=init=\/usr\/sbin\/init-beagle-flasher/' "$UENV_FILE"
    echo "Ensured cmdline flasher is disabled in rootfs uEnv.txt"
fi

# Copy the raw image into the rootfs (for the flasher to read)
# This is the image that will be dd'd to eMMC - it has cmdline disabled.
echo "Copying boneio-emmc.img into rootfs (this takes a while)..."
cp "${ROOTFS_IMG}" /tmp/flasher_rootfs/boneio-emmc.img

# Install flasher script
echo "Installing flasher script..."
cp "${FLASHER_SCRIPT}" /tmp/flasher_rootfs/usr/sbin/init-beagle-flasher-img
chmod +x /tmp/flasher_rootfs/usr/sbin/init-beagle-flasher-img

# Install OLED helper script (optional, for display feedback)
if [ -f "${OLED_SCRIPT}" ]; then
    cp "${OLED_SCRIPT}" /tmp/flasher_rootfs/usr/sbin/oled_msg.sh
    chmod +x /tmp/flasher_rootfs/usr/sbin/oled_msg.sh
    echo "Installed OLED helper script"
fi

if [ -f "${OLED_PYTHON_SCRIPT}" ]; then
    cp "${OLED_PYTHON_SCRIPT}" /tmp/flasher_rootfs/usr/sbin/oled_msg.py
    chmod +x /tmp/flasher_rootfs/usr/sbin/oled_msg.py
    echo "Installed OLED Python renderer"
fi

# Install fast boot splash scripts (smbus2-based, no luma dependency)
if [ -f "${OLED_BOOT_SPLASH}" ]; then
    cp "${OLED_BOOT_SPLASH}" /tmp/flasher_rootfs/usr/sbin/oled_boot_splash.py
    chmod +x /tmp/flasher_rootfs/usr/sbin/oled_boot_splash.py
    echo "Installed OLED boot splash script"
fi

if [ -f "${OLED_BOOT_SPLASH_SH}" ]; then
    cp "${OLED_BOOT_SPLASH_SH}" /tmp/flasher_rootfs/usr/sbin/oled_boot_splash.sh
    chmod +x /tmp/flasher_rootfs/usr/sbin/oled_boot_splash.sh
    echo "Installed OLED boot splash wrapper"
fi

# NOW enable cmdline flasher on the SD card's own uEnv.txt
# This only affects the SD card boot - the image inside has it disabled.
if [ -f "$UENV_FILE" ]; then
    echo "" >> "$UENV_FILE"
    echo "# DD-based eMMC flasher (active only on SD card)" >> "$UENV_FILE"
    echo "cmdline=init=/usr/sbin/init-beagle-flasher-img net.ifnames=0" >> "$UENV_FILE"
    echo "Enabled cmdline flasher in SD card uEnv.txt"
else
    echo "WARNING: uEnv.txt not found at $UENV_FILE"
fi

sync

echo ""
echo "--- Step 5/5: Cleanup ---"
umount /tmp/flasher_rootfs
sync

FINAL_SIZE=$(blockdev --getsize64 "${SD_DEVICE}")
FINAL_SIZE_MB=$((FINAL_SIZE / 1024 / 1024))

echo ""
echo "================================================================================"
echo "SUCCESS! Flasher SD card created."
echo ""
echo "SD card now contains:"
echo "  - Bootable Debian system"
echo "  - /boneio-emmc.img (image to flash to eMMC)"
echo "  - Flasher init script"
echo ""
echo "To flash a BeagleBone:"
echo "  1. Insert SD card into BeagleBone"
echo "  2. Hold boot button and power on"
echo "  3. Wait for LEDs to indicate completion (all 4 LEDs on, ~5-8 minutes)"
echo "  4. Remove SD card and power on to boot from eMMC"
echo "================================================================================"
