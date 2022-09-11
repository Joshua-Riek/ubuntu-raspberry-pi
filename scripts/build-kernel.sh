#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

# Download the raspberry pi linux kernel source
if [ ! -d linux ]; then
    git clone --depth=1 --progress -b rpi-5.10.y https://github.com/raspberrypi/linux
fi
cd linux

# Set kernel config 
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2711_defconfig
./scripts/config --disable CONFIG_DEBUG_INFO

# Set custom kernel version
./scripts/config --enable CONFIG_LOCALVERSION_AUTO
echo "-raspberry-pi4" > .scmversion
echo "0" > .version

# Compile kernel into deb package
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j "$(nproc)"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j "$(nproc)" bindeb-pkg
