#!/bin/sh -ex

# Root, but just due to permissions for swtpm-sock
if [ "$(id -u)" -ne 0 ]; then
    printf "Please run as root\n"
    exit 1
fi
if [ $# -lt 1 ]; then
    printf "Usage: %s <image_file>\n" "$(basename "$0")"
    exit 1
fi
img=$1
shift
format=$(qemu-img info --output=json "$img" | jq -r .format)

nvram=OVMF_VARS_4M.ms.fd
# snakeoil for self-signed shim
if [ -f OVMF_VARS_4M.snakeoil.fd ]; then
    nvram=OVMF_VARS_4M.snakeoil.fd
fi
if [ ! -f "$nvram" ]; then
    printf "Please copy around UEFI vars file\n"
    exit 1
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

sb_bios=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd

/usr/bin/qemu-system-x86_64 -enable-kvm -smp 2 -m 4096 \
	-machine q35 \
	-cpu host \
	-global ICH9-LPC.disable_s3=1 \
	-drive file=$sb_bios,if=pflash,format="$format",unit=0,readonly=on \
	-drive file="$nvram",if=pflash,format=raw,unit=1 \
	-netdev user,id=net0,hostfwd=tcp::8022-:22 \
	-device virtio-net-pci,netdev=net0 \
	-chardev socket,id=chrtpm,path=/var/snap/test-snapd-swtpm/current/swtpm-sock \
	-tpmdev emulator,id=tpm0,chardev=chrtpm \
	-device tpm-tis,tpmdev=tpm0 \
	-drive "file=$img",if=none,format=raw,id=disk1 \
	-device virtio-blk-pci,drive=disk1,bootindex=1,serial=DISK000A \
	-serial mon:stdio "$@"
