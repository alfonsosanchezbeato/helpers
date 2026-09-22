#!/bin/sh -ex

# Root, but just due to permissions of swtpm-sock... I think
if [ "$(id -u)" -ne 0 ]; then
    printf "Please run as root\n"
    exit 1
fi
if [ $# -ne 1 ]; then
    printf "Usage: %s <image_file>\n" "$(basename "$0")"
    exit 1
fi
if [ ! -f AAVMF_VARS.ms.fd ]; then
    printf "Please copy around UEFI vars file\n"
fi
if [ -f tpm2-00.permall ]; then
    # We have TPM state
    snap stop test-snapd-swtpm
    cp tpm2-00.permall /var/snap/test-snapd-swtpm/current/
    snap start test-snapd-swtpm
else
    # Reset TPM
    snap stop test-snapd-swtpm
    rm -f /var/snap/test-snapd-swtpm/current/tpm2-00.permall
    snap start test-snapd-swtpm
fi

finish() {
    # Backup TPM state
    cp /var/snap/test-snapd-swtpm/current/tpm2-00.permall .
}
trap finish EXIT

# RHEL-family QEMU packages use /usr/libexec/qemu-kvm for the native system
# emulator. Keep the upstream binary name for cross-architecture emulation.
if [ -z "${QEMU_BIN:-}" ]; then
    QEMU_BIN=qemu-system-aarch64
    if [ -f /etc/redhat-release ] && [ "$(uname -m)" = aarch64 ] && \
            [ -x /usr/libexec/qemu-kvm ]; then
        QEMU_BIN=/usr/libexec/qemu-kvm
    fi
fi

# Locate the aarch64 UEFI firmware. Search the well-known Linux AAVMF/edk2
# locations first, then the data dirs QEMU itself reports via "-L help" (this
# covers Homebrew/macOS regardless of the installed version).
firmware=
fw_names="AAVMF_CODE.fd QEMU_EFI.fd QEMU_EFI-pflash.raw QEMU_EFI-silent-pflash.raw edk2-aarch64-code.fd"
fw_dirs="/usr/share/AAVMF /usr/share/qemu-efi-aarch64 /usr/share/edk2/aarch64 /usr/share/qemu"
fw_dirs="$fw_dirs $("$QEMU_BIN" -L help 2>/dev/null || true)"

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

tpm_sock=/var/snap/test-snapd-swtpm/current/swtpm-sock

# Re: random numbers, see https://bugzilla.redhat.com/show_bug.cgi?id=1579518

"$QEMU_BIN" -machine virt -cpu cortex-a57 -smp 2 -m 4096 \
 	-drive file="$firmware",if=pflash,format=raw,unit=0,readonly=on \
 	-drive file=AAVMF_VARS.ms.fd,if=pflash,format=raw,unit=1 \
        -netdev user,id=net0,hostfwd=tcp::8022-:22 \
        -device virtio-net-pci,netdev=net0 \
 	-drive "file=$1",if=none,format=raw,id=disk1 \
	-device virtio-blk-pci,drive=disk1,bootindex=1,serial=DISK000A \
        -chardev socket,id=chrtpm,path=$tpm_sock \
	-tpmdev emulator,id=tpm0,chardev=chrtpm \
	-device tpm-tis-device,tpmdev=tpm0 \
        -object rng-random,filename=/dev/urandom,id=rng0 \
        -device virtio-rng-pci,rng=rng0,id=rng-device0 \
        -device virtio-gpu-pci \
        -device qemu-xhci,id=xhci \
        -device usb-kbd,bus=xhci.0 \
        -device virtio-mouse \
        -serial mon:stdio
