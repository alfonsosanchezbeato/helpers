#!/bin/sh -exu

# To install dependencies:
# sudo apt install qemu-system-arm qemu-efi-aarch64

if [ $# -lt 2 ]; then
    printf "Usage: %s <iso> <disk_file>\n" "$(basename "$0")"
    exit 1
fi
image=$1
disk=$2
shift 2

# The DGX OS arm64 ISO ships a 64 KB-page kernel. On Apple Silicon, HVF exposes
# the host CPU granule support and that kernel can fail in the EFI stub with
# start_image() returned 0x8000000000000003. TCG's max CPU advertises the needed
# CPU features, but is slower. For non-64k kernels, override with:
# QEMU_ACCEL=hvf QEMU_CPU=host ./run-iso-arm64.sh <iso> <disk_file>
: "${QEMU_ACCEL:=tcg,thread=multi}"
# QEMU_CPU: use max or cortex-a57 on x86
: "${QEMU_CPU:=max}"
: "${QEMU_SMP:=2}"
: "${QEMU_MEM:=4096}"
: "${DISK_SIZE:=50G}"

rm -f "$disk"
truncate -s "$DISK_SIZE" "$disk"

# Locate the aarch64 UEFI firmware. Search the well-known Linux AAVMF/edk2
# locations first, then the data dirs QEMU itself reports via "-L help" (this
# covers Homebrew/macOS regardless of the installed version).
firmware=
fw_names="AAVMF_CODE.fd QEMU_EFI.fd QEMU_EFI-pflash.raw QEMU_EFI-silent-pflash.raw edk2-aarch64-code.fd"
fw_dirs="/usr/share/AAVMF /usr/share/qemu-efi-aarch64 /usr/share/edk2/aarch64 /usr/share/qemu"
fw_dirs="$fw_dirs $(qemu-system-aarch64 -L help 2>/dev/null || true)"

for d in $fw_dirs; do
    [ -d "$d" ] || continue
    for n in $fw_names; do
        if [ -f "$d/$n" ]; then
            firmware=$d/$n
            break 2
        fi
    done
done

if [ -z "$firmware" ]; then
    printf "Could not locate aarch64 UEFI firmware\n" >&2
    exit 1
fi

# See also https://jimmyg.org/blog/2024/macos-qemu/index.html
qemu-system-aarch64 -machine virt -accel "$QEMU_ACCEL" -cpu "$QEMU_CPU" \
                        -smp "$QEMU_SMP" -m "$QEMU_MEM" \
                        -bios "$firmware" \
                        -cdrom "$image" \
                        -netdev user,id=net0,hostfwd=tcp::8022-:22 \
                        -device virtio-net-pci,netdev=net0 \
                        -drive file="$disk",if=none,format=raw,id=disk1 \
                        -device virtio-blk-pci,drive=disk1,serial=DISK000A \
                        -device virtio-gpu-pci \
                        -device virtio-keyboard \
                        -device virtio-mouse \
                        -serial mon:stdio "$@"
