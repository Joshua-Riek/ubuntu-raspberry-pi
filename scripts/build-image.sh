#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

function cleanup_loopdev {
    sync --file-system
    sync

    if [ -b "${loop}" ]; then
        umount "${loop}"* 2> /dev/null || true
        losetup -d "${loop}" 2> /dev/null || true
    fi
}
trap cleanup_loopdev EXIT

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p images build && cd build

if [ ! -d firmware ]; then
    echo "Error: could not find raspberry pi firmware, please run build-rootfs.sh"
    exit 1
fi

for rootfs in *.rootfs.tar.xz; do
    if [ ! -e "${rootfs}" ]; then
        echo "Error: could not find any rootfs tarfile, please run build-rootfs.sh"
        exit 1
    fi

    # Create an empty disk image
    img="../images/$(basename "${rootfs}" .rootfs.tar.xz).img"
    size="$(xz -l "${rootfs}" | tail -n +2 | sed 's/,//g' | awk '{print int($5 + 1)}')"
    truncate -s "$(( size + 2048 + 512 ))M" "${img}"

    # Create loop device for disk image
    loop="$(losetup -f)"
    losetup "${loop}" "${img}"
    disk="${loop}"

    # Ensure disk is not mounted
    mount_point=/tmp/mnt
    umount "${disk}"* 2> /dev/null || true
    umount ${mount_point}/* 2> /dev/null || true
    mkdir -p ${mount_point}

    # Setup partition table
    dd if=/dev/zero of="${disk}" count=4096 bs=512
    parted --script "${disk}" \
    mklabel msdos \
    mkpart primary fat32 0% 512MiB \
    mkpart primary ext4 512MiB 100%

    set +e

    # Create partitions
    (
    echo t
    echo 1
    echo c
    echo t
    echo 2
    echo 83
    echo a
    echo 1
    echo w
    ) | fdisk "${disk}"

    set -eE

    partprobe "${disk}"

    sleep 2

    # Generate random uuid for bootfs
    boot_uuid=$(uuidgen | head -c8)

    # Generate random uuid for rootfs
    root_uuid=$(uuidgen)
    
    # Create filesystems on partitions
    partition_char="$(if [[ ${disk: -1} == [0-9] ]]; then echo p; fi)"
    mkfs.vfat -i "${boot_uuid}" -F32 -n boot "${disk}${partition_char}1"
    dd if=/dev/zero of="${disk}${partition_char}2" bs=1KB count=10 > /dev/null
    mkfs.ext4 -U "${root_uuid}" -L root "${disk}${partition_char}2"

    # Mount partitions
    mkdir -p ${mount_point}/{boot,root} 
    mount "${disk}${partition_char}1" ${mount_point}/boot
    mount "${disk}${partition_char}2" ${mount_point}/root

    # Copy the rootfs to root partition
    echo -e "Decompressing $(basename "${rootfs}")\n"
    tar -xpJf "${rootfs}" -C ${mount_point}/root

    # Create fstab entries
    mkdir -p ${mount_point}/root/boot/firmware
    boot_uuid="${boot_uuid:0:4}-${boot_uuid:4:4}"
    echo "# <file system>      <mount point>  <type>  <options>   <dump>  <fsck>" > ${mount_point}/root/etc/fstab
    echo "UUID=${boot_uuid^^}  /boot/firmware vfat    defaults    0       2" >> ${mount_point}/root/etc/fstab
    echo "UUID=${root_uuid,,}  /              ext4    defaults    0       1" >> ${mount_point}/root/etc/fstab
    echo "/swapfile            none           swap    sw          0       0" >> ${mount_point}/root/etc/fstab

    # Extract grub arm64-efi to host system 
    if [ ! -d "/usr/lib/grub/arm64-efi" ]; then
        rm -f /usr/lib/grub/arm64-efi
        ln -s ${mount_point}/root/usr/lib/grub/arm64-efi /usr/lib/grub/arm64-efi
    fi

    # Install grub 
    mkdir -p ${mount_point}/boot/efi/boot
    mkdir -p ${mount_point}/boot/boot/grub
    grub-install --target=arm64-efi --efi-directory=${mount_point}/boot --boot-directory=${mount_point}/boot/boot --removable --recheck

    # Remove grub arm64-efi if extracted
    if [ -L "/usr/lib/grub/arm64-efi" ]; then
        rm -f /usr/lib/grub/arm64-efi
    fi

    # Grub config
    cat > ${mount_point}/boot/boot/grub/grub.cfg << EOF
insmod gzio
set background_color=black
set default=0
set timeout=10

GRUB_RECORDFAIL_TIMEOUT=

menuentry 'Boot' {
    search --no-floppy --fs-uuid --set=root ${root_uuid}
    linux /boot/vmlinuz root=UUID=${root_uuid} console=serial0,115200 console=tty1 rootfstype=ext4 rootwait rw
    initrd /boot/initrd.img
}
EOF

    # Uboot script
    cat > ${mount_point}/boot/boot.cmd << EOF
env set bootargs "root=UUID=${root_uuid} console=serial0,115200 console=tty1 rootfstype=ext4 rootwait rw"
ext4load \${devtype} \${devnum}:2 \${ramdisk_addr_r} /boot/vmlinuz
unzip \${ramdisk_addr_r} \${kernel_addr_r}
ext4load \${devtype} \${devnum}:2 \${ramdisk_addr_r} /boot/initrd.img
booti \${kernel_addr_r} \${ramdisk_addr_r}:\${filesize} \${fdt_addr}
EOF
    mkimage -A arm64 -O linux -T script -C none -n "Boot Script" -d ${mount_point}/boot/boot.cmd ${mount_point}/boot/boot.scr
    rm ${mount_point}/boot/boot.cmd

    # Raspberry pi config 
    cat > ${mount_point}/boot/config.txt << EOF
[all]
kernel=u-boot-rpi-arm64.bin

[pi3]
kernel=u-boot-rpi-3.bin

[pi4]
kernel=u-boot-rpi-4.bin
dtoverlay=vc4-kms-v3d-pi4
max_framebuffers=2
arm_boost=1

[all]
# Enable the audio output, I2C and SPI interfaces on the GPIO header. As these
# parameters related to the base device-tree they must appear *before* any
# other dtoverlay= specification
dtparam=audio=on
dtparam=i2c_arm=on
dtparam=spi=on

# Comment out the following line if the edges of the desktop appear outside
# the edges of your display
disable_overscan=1

# If you have issues with audio, you may try uncommenting the following line
# which forces the HDMI output into HDMI mode instead of DVI (which doesn't
# support audio output)
#hdmi_drive=2

# Enable the serial pins
enable_uart=1

# Autoload overlays for any recognized cameras or displays that are attached
# to the CSI/DSI ports. Please note this is for libcamera support, *not* for
# the legacy camera stack
camera_auto_detect=1
display_auto_detect=1

# Config settings specific to arm64
arm_64bit=1
dtoverlay=dwc2

[cm4]
# Enable the USB2 outputs on the IO board (assuming your CM4 is plugged into
# such a board)
dtoverlay=dwc2,dr_mode=host

[all]
EOF
    # Copy uboot binary
    cp u-boot-rpi-3.bin ${mount_point}/boot
    cp u-boot-rpi-4.bin ${mount_point}/boot
    cp u-boot-rpi-arm64.bin ${mount_point}/boot

    # Copy raspberry pi firmware
    cp -r firmware/boot/* ${mount_point}/boot
    rm -f ${mount_point}/boot/{bcm2708*,bcm2709*,*.img}

    sync --file-system
    sync

    # Umount partitions
    umount "${disk}${partition_char}1"
    umount "${disk}${partition_char}2"

    # Remove loop device
    losetup -d "${loop}"

    echo -e "\nCompressing $(basename "${img}.xz")\n"
    xz -9 --extreme --force --keep --quiet --threads=0 "${img}"
    rm -f "${img}"
done