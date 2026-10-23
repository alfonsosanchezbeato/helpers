#!/bin/bash -ex

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
