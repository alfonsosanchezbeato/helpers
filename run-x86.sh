#!/bin/bash -ex

if [ $# -lt 1 ]; then
    printf "Usage: %s <image_file> <more_qemu_options>\n" "$(basename "$0")"
    exit 1
fi

img=$1
shift

: "${QEMU_SSH_PORT:=8022}"
: "${QEMU_SMP:=2}"
: "${QEMU_MEM:=4096}"

# RHEL-family QEMU packages use /usr/libexec/qemu-kvm for the native system
# emulator. Keep the upstream binary name for cross-architecture emulation.
if [ -z "${QEMU_BIN:-}" ]; then
    QEMU_BIN=qemu-system-x86_64
    if [ -f /etc/redhat-release ] && [ "$(uname -m)" = x86_64 ] && \
            [ -x /usr/libexec/qemu-kvm ]; then
        QEMU_BIN=/usr/libexec/qemu-kvm
    fi
fi

# For older UC: driver cannot be virtio-blk-pci as kernels did not include
# that kernel module in the initramfs. Alternative: use "driver=ide-hd".
disk_driver=virtio-blk-pci
if sfdisk -d "$img" | grep 'name="writable"'
then disk_driver=ide-hd
fi

format=$(qemu-img info --output=json "$img" | jq -r .format)

# Locate the x86_64 UEFI firmware. Search the well-known Linux OVMF locations
# first, then the data dirs QEMU itself reports via "-L help" (this covers
# Homebrew/macOS regardless of the installed version).
firmware=
accel="-enable-kvm"
fw_names=(OVMF_CODE_4M.fd OVMF_CODE.fd edk2-x86_64-code.fd)
fw_dirs=(/usr/share/OVMF /usr/share/qemu)
while read -r d; do
    [ -d "$d" ] && fw_dirs+=("$d")
done < <("$QEMU_BIN" -L help 2>/dev/null || true)

for d in "${fw_dirs[@]}"; do
    for n in "${fw_names[@]}"; do
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

"$QEMU_BIN" $accel \
    -smp "$QEMU_SMP" -m "$QEMU_MEM" \
    -drive file="$firmware",if=pflash,unit=0,readonly=on \
    -netdev user,id=net0,hostfwd=tcp::"$QEMU_SSH_PORT"-:22,hostfwd=tcp::$((QEMU_SSH_PORT+100))-:31111,hostname=qemu \
    -device virtio-net-pci,netdev=net0 \
    -drive file="$img",if=none,format="$format",id=disk1 \
    -device "$disk_driver",drive=disk1,bootindex=1,serial=DISK000A \
    -usb -device usb-ehci,id=ehci \
    -nographic \
    -serial mon:stdio "$@"
