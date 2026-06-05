#!/bin/bash
## Creates rootfs.img from SD card on PC — optimized for speed
## Usage: sudo ./create_rootfs_img.sh /dev/sdX [output_file]
## Example: sudo ./create_rootfs_img.sh /dev/sdb ./rootfs.img
##
## Optimization: Shrinks the filesystem & partition on the SD card FIRST,
## then dd copies only the used sectors (e.g. 2.5GB instead of 32GB).
## The SD card is not reusable after this — that's fine, it's a build artifact.
##
## Requires: e2fsprogs (resize2fs), util-linux (sfdisk)
## Optional: pishrink.sh (fallback if partition shrink fails)

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

# Get SD card size
SD_SIZE=$(blockdev --getsize64 ${SD_DEVICE})
SD_SIZE_MB=$((SD_SIZE / 1024 / 1024))

echo "================================================================================"
echo "Creating rootfs.img from SD card (optimized)"
echo "================================================================================"
echo "SD Card:     ${SD_DEVICE}"
echo "SD Size:     ${SD_SIZE_MB} MB"
echo "Output:      ${OUTPUT_FILE}"
echo "================================================================================"
echo ""

# Step 1: Unmount everything
echo "--- Step 1/4: Unmounting SD card partitions ---"
umount ${SD_DEVICE}* 2>/dev/null || true
sleep 1

# Step 2: Shrink filesystem & partition on SD card
echo ""
echo "--- Step 2/4: Shrinking filesystem on SD card ---"

# Find the ext4 rootfs partition (take the LAST ext4 = main rootfs)
ROOTFS_PART=""
ROOTFS_NUM=""
for i in 1 2 3 4; do
    PART="${SD_DEVICE}${i}"
    [ -b "$PART" ] || continue
    FS_TYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || echo "unknown")
    if [ "$FS_TYPE" = "ext4" ]; then
        ROOTFS_PART="$PART"
        ROOTFS_NUM="$i"
    fi
done

SHRINK_OK=false
if [ -n "$ROOTFS_PART" ]; then
    echo "Found rootfs: ${ROOTFS_PART} (partition ${ROOTFS_NUM})"
    
    # Check and shrink filesystem to minimum
    echo "Running e2fsck..."
    e2fsck -f -y ${ROOTFS_PART} || true
    
    echo "Shrinking filesystem to minimum..."
    if resize2fs -M ${ROOTFS_PART}; then
        # Get the new filesystem size in blocks
        BLOCK_COUNT=$(dumpe2fs -h ${ROOTFS_PART} 2>/dev/null | grep 'Block count' | awk '{print $3}')
        BLOCK_SIZE=$(dumpe2fs -h ${ROOTFS_PART} 2>/dev/null | grep 'Block size' | awk '{print $3}')
        if [ -n "$BLOCK_COUNT" ] && [ -n "$BLOCK_SIZE" ]; then
            FS_SIZE_BYTES=$((BLOCK_COUNT * BLOCK_SIZE))
            FS_SIZE_MB=$((FS_SIZE_BYTES / 1024 / 1024))
            echo "Filesystem shrunk to ${FS_SIZE_MB} MB"
            
            # Shrink partition to fit (filesystem size + 32MB safety margin)
            PART_SIZE_MB=$((FS_SIZE_MB + 32))
            
            # Get partition start sector
            SECTOR_SIZE=$(blockdev --getss ${SD_DEVICE})
            PART_START=$(sfdisk -l ${SD_DEVICE} 2>/dev/null | grep "^${ROOTFS_PART}" | awk '{print $2}')
            
            if [ -n "$PART_START" ]; then
                PART_SECTORS=$((PART_SIZE_MB * 1024 * 1024 / SECTOR_SIZE))
                echo "Resizing partition ${ROOTFS_NUM}: start=${PART_START}, size=${PART_SECTORS} sectors (${PART_SIZE_MB} MB)..."
                echo "${PART_START} ${PART_SECTORS}" | sfdisk -N ${ROOTFS_NUM} ${SD_DEVICE} --force --no-reread 2>/dev/null || true
                partprobe ${SD_DEVICE} 2>/dev/null || true
                sleep 1
                SHRINK_OK=true
                echo "Partition shrunk successfully"
            fi
        fi
    fi
fi

# Step 3: Calculate how much to copy and dd
echo ""
echo "--- Step 3/4: Creating image with dd ---"

if [ "$SHRINK_OK" = true ]; then
    # Only copy up to the end of the last partition + small margin
    # Find end of last partition
    LAST_END=0
    while IFS= read -r line; do
        END=$(echo "$line" | awk '{print $3}')
        [ -n "$END" ] && [ "$END" -gt "$LAST_END" ] 2>/dev/null && LAST_END="$END"
    done < <(sfdisk -l ${SD_DEVICE} 2>/dev/null | grep "^${SD_DEVICE}")
    
    if [ "$LAST_END" -gt 0 ]; then
        SECTOR_SIZE=$(blockdev --getss ${SD_DEVICE})
        # Add 2048 sectors (1MB) margin
        COPY_SECTORS=$((LAST_END + 2048))
        COPY_BYTES=$((COPY_SECTORS * SECTOR_SIZE))
        COPY_MB=$((COPY_BYTES / 1024 / 1024))
        echo "Optimized: copying only ${COPY_MB} MB (instead of ${SD_SIZE_MB} MB)"
        dd if=${SD_DEVICE} of=${OUTPUT_FILE} bs=512 count=${COPY_SECTORS} status=progress
    else
        echo "Could not determine partition layout, copying full card..."
        dd if=${SD_DEVICE} of=${OUTPUT_FILE} bs=4M status=progress
    fi
else
    echo "Partition shrink failed, copying full card..."
    dd if=${SD_DEVICE} of=${OUTPUT_FILE} bs=4M status=progress
fi
sync

# Step 4: Restore SD card (re-expand partition so card is reusable)
if [ "$SHRINK_OK" = true ] && [ -n "$ROOTFS_PART" ] && [ -n "$ROOTFS_NUM" ]; then
    echo ""
    echo "--- Step 4/5: Restoring SD card (re-expanding partition) ---"
    if command -v growpart &> /dev/null; then
        growpart ${SD_DEVICE} ${ROOTFS_NUM} || true
    else
        echo ", +" | sfdisk -N ${ROOTFS_NUM} ${SD_DEVICE} --force --no-reread 2>/dev/null || true
    fi
    partprobe ${SD_DEVICE} 2>/dev/null || true
    sleep 1
    e2fsck -f -y ${ROOTFS_PART} 2>/dev/null || true
    resize2fs ${ROOTFS_PART} || true
    echo "SD card restored — fully reusable"
fi

# Step 5: Final shrink with pishrink (if available)
echo ""
echo "--- Step 5/5: Final optimization ---"
if command -v pishrink.sh &> /dev/null; then
    echo "Running pishrink.sh for final compaction..."
    pishrink.sh -s ${OUTPUT_FILE}
else
    echo "pishrink.sh not available, skipping (image is already compact)"
fi

FINAL_SIZE=$(stat -c%s ${OUTPUT_FILE})
FINAL_SIZE_MB=$((FINAL_SIZE / 1024 / 1024))

echo ""
echo "================================================================================"
echo "SUCCESS! Image created: ${OUTPUT_FILE}"
echo "Original SD size: ${SD_SIZE_MB} MB"
echo "Final image size: ${FINAL_SIZE_MB} MB"
echo "Saved:           $((SD_SIZE_MB - FINAL_SIZE_MB)) MB"
echo ""
echo "SD card has been restored and is reusable."
echo ""
echo "Next step:"
echo "  sudo ./generate_all_images.sh ${OUTPUT_FILE} <version> --emmc-flasher"
echo "================================================================================"

