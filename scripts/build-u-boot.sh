#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

# Download and build u-boot
if [ ! -d u-boot ]; then
    git clone --progress --depth=1 -b v2022.01 http://git.denx.de/u-boot.git
fi
cd u-boot

# Clean all and set defconfig
make ARCH=arm CROSS_COMPILE=aarch64-linux-gnu- rpi_4_defconfig

# Compile u-boot binary
make ARCH=arm CROSS_COMPILE=aarch64-linux-gnu- -j "$(nproc)"
