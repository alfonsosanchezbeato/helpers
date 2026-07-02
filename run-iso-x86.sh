#!/bin/sh -exu

if [ $# -ne 2 ]; then
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
: "${QEMU_SSH_PORT:=8022}"
: "${DISK_SIZE:=50G}"

rm -f "$disk"
truncate -s "$DISK_SIZE" "$disk"

disk_driver=virtio-blk-pci

# Locate the x86_64 UEFI firmware. Search the well-known Linux OVMF locations
# first, then the data dirs QEMU itself reports via "-L help" (this covers
# Homebrew/macOS regardless of the installed version).
firmware=
accel="-enable-kvm"
fw_names="OVMF_CODE_4M.fd OVMF_CODE.fd edk2-x86_64-code.fd"
fw_dirs="/usr/share/OVMF /usr/share/qemu"
fw_dirs="$fw_dirs $(qemu-system-x86_64 -L help 2>/dev/null)"

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
    printf "Could not locate x86_64 UEFI firmware\n" >&2
    exit 1
fi

# No KVM on a non-Linux host (e.g. Apple Silicon); fall back to TCG emulation.
[ -e /dev/kvm ] || accel=

# See also https://jimmyg.org/blog/2024/macos-qemu/index.html
qemu-system-x86_64 $accel \
                        -smp "$QEMU_SMP" -m "$QEMU_MEM" \
                        -drive file="$firmware",if=pflash,unit=0,readonly=on \
                        -cdrom "$image" \
                        -netdev user,id=net0,hostfwd=tcp::"$QEMU_SSH_PORT"-:22,hostfwd=tcp::$((QEMU_SSH_PORT+100))-:31111,hostname=qemu \
                        -device virtio-net-pci,netdev=net0 \
                        -drive file="$disk",if=none,format=raw,id=disk1 \
                        -device "$disk_driver",drive=disk1,serial=DISK000A \
                        -nographic \
                        -serial mon:stdio "$@"
