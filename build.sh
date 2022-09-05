#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

# Build the U-Boot bootloader
./build-u-boot.sh

# Build the Linux kernel and Device Tree Blobs
./build-kernel.sh

# Build the root file system
./build-rootfs.sh

# Build the Ubuntu preinstalled images
./build-image.sh