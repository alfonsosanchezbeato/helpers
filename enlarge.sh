#!/bin/bash -ex
#
# enlarge.sh - Double the size of the last partition of a GPT disk image.
#
# Usage: enlarge.sh <image-file>
#
# The partition located at the end of the image (highest start sector) is
# found, the image file is grown by that partition's current size, the
# backup GPT header is moved to the new end, and the partition and its ext
# filesystem are extended to fill the new space.
#
# Requires: sfdisk, sgdisk, growpart, jq, e2fsck, resize2fs, losetup (sudo).

img=$1

# Inspect the current layout.
sfdisk -l "$img"

# Find the partition that ends last in the image (highest start sector).
table=$(sfdisk --json "$img")
last=$(jq -c '.partitiontable.partitions | max_by(.start)' <<<"$table")
part_node=$(jq -r '.node' <<<"$last")
part_num=${part_node##*[!0-9]}
part_sectors=$(jq -r '.size' <<<"$last")
sector_size=$(jq -r '.partitiontable.sectorsize // 512' <<<"$table")

# Enlarge the image by the partition's current size.
truncate -s "+$((part_sectors * sector_size))" "$img"

# Move the backup GPT header to the new end of the image.
sgdisk -e "$img"

# Extend the last partition into the newly added space.
growpart "$img" "$part_num"

# Extend fs
loopdev=$(sudo losetup --find --show --partscan "$img")
sudo e2fsck -f "${loopdev}p${part_num}"
sudo resize2fs "${loopdev}p${part_num}"
sudo losetup -d "$loopdev"
