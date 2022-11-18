#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

if [ ! -d linux ]; then
    echo "Error: could not find the kernel source code, please run build-kernel.sh"
    exit 1
fi

# Download the raspberry pi firmware
if [ ! -d firmware ]; then
    git clone --depth 1 --progress -b 1.20220830 https://github.com/raspberrypi/firmware.git 
fi

# These env vars can cause issues with chroot
unset TMP
unset TEMP
unset TMPDIR

# Debootstrap options
arch=arm64
release=focal
mirror=http://ports.ubuntu.com/ubuntu-ports
chroot_dir=rootfs

# Clean chroot dir and make sure folder is not mounted
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true
rm -rf ${chroot_dir}
mkdir -p ${chroot_dir}

# Install the base system into a directory 
qemu-debootstrap --arch ${arch} ${release} ${chroot_dir} ${mirror}

# Use a more complete sources.list file 
cat > ${chroot_dir}/etc/apt/sources.list << EOF
# See http://help.ubuntu.com/community/UpgradeNotes for how to upgrade to
# newer versions of the distribution.
deb ${mirror} ${release} main restricted
# deb-src ${mirror} ${release} main restricted

## Major bug fix updates produced after the final release of the
## distribution.
deb ${mirror} ${release}-updates main restricted
# deb-src ${mirror} ${release}-updates main restricted

## N.B. software from this repository is ENTIRELY UNSUPPORTED by the Ubuntu
## team. Also, please note that software in universe WILL NOT receive any
## review or updates from the Ubuntu security team.
deb ${mirror} ${release} universe
# deb-src ${mirror} ${release} universe
deb ${mirror} ${release}-updates universe
# deb-src ${mirror} ${release}-updates universe

## N.B. software from this repository is ENTIRELY UNSUPPORTED by the Ubuntu
## team, and may not be under a free licence. Please satisfy yourself as to
## your rights to use the software. Also, please note that software in
## multiverse WILL NOT receive any review or updates from the Ubuntu
## security team.
deb ${mirror} ${release} multiverse
# deb-src ${mirror} ${release} multiverse
deb ${mirror} ${release}-updates multiverse
# deb-src ${mirror} ${release}-updates multiverse

## N.B. software from this repository may not have been tested as
## extensively as that contained in the main release, although it includes
## newer versions of some applications which may provide useful features.
## Also, please note that software in backports WILL NOT receive any review
## or updates from the Ubuntu security team.
deb ${mirror} ${release}-backports main restricted universe multiverse
# deb-src ${mirror} ${release}-backports main restricted universe multiverse

deb ${mirror} ${release}-security main restricted
# deb-src ${mirror} ${release}-security main restricted
deb ${mirror} ${release}-security universe
# deb-src ${mirror} ${release}-security universe
deb ${mirror} ${release}-security multiverse
# deb-src ${mirror} ${release}-security multiverse
EOF

# Mount the temporary API filesystems
mkdir -p ${chroot_dir}/{proc,sys,run,dev,dev/pts}
mount -t proc /proc ${chroot_dir}/proc
mount -t sysfs /sys ${chroot_dir}/sys
mount -o bind /dev ${chroot_dir}/dev
mount -o bind /dev/pts ${chroot_dir}/dev/pts

# Copy the the kernel, modules, and headers to the rootfs
if ! cp linux-{headers,image,libc}-*.deb ${chroot_dir}/tmp; then
    echo "Error: could not find the kernel deb packages, please run build-kernel.sh"
    exit 1
fi

# Download and update packages
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

# Generate localisation files
locale-gen en_US.UTF-8
update-locale LC_ALL="en_US.UTF-8"

# Download package information
DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends update

# Update installed packages
DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade

# Update installed packages and dependencies
DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends dist-upgrade

# Download and install generic packages
DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install \
bash-completion man-db manpages nano gnupg initramfs-tools linux-firmware \
ubuntu-drivers-common ubuntu-server dosfstools mtools parted ntfs-3g zip atop \
p7zip-full htop iotop pciutils lshw lsof cryptsetup exfat-fuse hwinfo dmidecode \
net-tools wireless-tools openssh-client openssh-server wpasupplicant ifupdown \
pigz wget curl grub-common grub2-common grub-efi-arm64 grub-efi-arm64-bin \
libraspberrypi-bin

# Clean package cache
apt-get -y autoremove && apt-get -y clean && apt-get -y autoclean
EOF

# Grab the kernel version
kernel_version="$(cat linux/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/')"

# Install kernel, modules, and headers
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

# Install the kernel, modules, and headers
dpkg -i /tmp/linux-{headers,image,libc}-*.deb
rm -rf /tmp/*

# Generate kernel module dependencies
depmod -a ${kernel_version}
update-initramfs -c -k ${kernel_version}

# Create kernel and component symlinks
cd /boot
ln -s initrd.img-${kernel_version} initrd.img
ln -s vmlinuz-${kernel_version} vmlinuz
ln -s System.map-${kernel_version} System.map
ln -s config-${kernel_version} config
EOF

# Create user accounts
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

# Setup user account
adduser --shell /bin/bash --gecos ubuntu --disabled-password ubuntu
usermod -a -G sudo ubuntu
chown -R ubuntu:ubuntu /home/ubuntu
mkdir -m 700 /home/ubuntu/.ssh
echo -e "root\nroot" | passwd ubuntu

# Root pass
echo -e "root\nroot" | passwd
EOF

# DNS
echo "nameserver 8.8.8.8" > ${chroot_dir}/etc/resolv.conf

# Hostname
echo "raspberry-pi" > ${chroot_dir}/etc/hostname

# Networking interfaces
cat > ${chroot_dir}/etc/network/interfaces << END
auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp

allow-hotplug enp0s3
iface enp0s3 inet dhcp

allow-hotplug wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
END

# Hosts file
cat > ${chroot_dir}/etc/hosts << END
127.0.0.1       localhost
127.0.1.1       raspberry-pi

::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
ff02::3         ip6-allhosts
END

# WIFI
cat > ${chroot_dir}/etc/wpa_supplicant/wpa_supplicant.conf << END
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="your_home_ssid"
    psk="your_home_psk"
    key_mgmt=WPA-PSK
    priority=1
}

network={
    ssid="your_work_ssid"
    psk="your_work_psk"
    key_mgmt=WPA-PSK
    priority=2
}
END

# Sapfile
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

dd if=/dev/zero of=/tmp/swapfile bs=1024 count=2097152
chmod 600 /tmp/swapfile
mkswap /tmp/swapfile
mv /tmp/swapfile /swapfile
EOF

# Serial console resize script
cat > ${chroot_dir}/etc/profile.d/serial-console.sh << 'END'
rsz() {
    if [[ -t 0 && $# -eq 0 ]]; then
        local IFS='[;' R escape geometry x y
        echo -en '\e7\e[r\e[999;999H\e[6n\e8'
        read -rsd R escape geometry
        x="${geometry##*;}"; y="${geometry%%;*}"
        if [[ "${COLUMNS}" -eq "${x}" && "${LINES}" -eq "${y}" ]]; then 
            true
        else 
            stty cols "${x}" rows "${y}"
        fi
    else
        echo 'Usage: rsz'
    fi
}
case $(/usr/bin/tty) in
    /dev/ttyAMA0|/dev/ttyS0|/dev/ttyGS0|/dev/ttyLP1)
        export LANG=C
        rsz
        ;;
esac
END

# Expand root filesystem on first boot
cat > ${chroot_dir}/etc/init.d/expand-rootfs.sh << 'END'
#!/bin/bash
### BEGIN INIT INFO
# Provides: expand-rootfs.sh
# Required-Start:
# Required-Stop:
# Default-Start: 2 3 4 5 S
# Default-Stop:
# Short-Description: Resize the root filesystem to fill partition
# Description:
### END INIT INFO

# Get the root partition
partition_root="$(findmnt -n -o SOURCE /)"
partition_name="$(lsblk -no name "${partition_root}")"
partition_pkname="$(lsblk -no pkname "${partition_root}")"
partition_num="$(echo "${partition_name}" | grep -Eo '[0-9]+$')"

# Get size of disk and root partition
partition_start="$(cat /sys/block/${partition_pkname}/${partition_name}/start)"
partition_end="$(( partition_start + $(cat /sys/block/${partition_pkname}/${partition_name}/size)))"
partition_newend="$(( $(cat /sys/block/${partition_pkname}/size) - 8))"

# Resize partition and filesystem
if [ "${partition_newend}" -gt "${partition_end}" ];then
    echo -e "Yes\n100%" | parted "/dev/${partition_pkname}" resizepart "${partition_num}" ---pretend-input-tty
    partx -u "/dev/${partition_pkname}"
    resize2fs "/dev/${partition_name}"
    sync
fi

# Remove script
update-rc.d expand-rootfs.sh remove
END
chmod +x ${chroot_dir}/etc/init.d/expand-rootfs.sh

# Install init script
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

update-rc.d expand-rootfs.sh defaults
EOF

# Remove release upgrade motd
rm -f ${chroot_dir}/var/lib/ubuntu-release-upgrader/release-upgrade-available
sed -i 's/^Prompt.*/Prompt=never/' ${chroot_dir}/etc/update-manager/release-upgrades

# Umount the temporary API filesystems
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true

# Tar the entire rootfs
cd ${chroot_dir} && XZ_OPT="-0 -T0" tar -cpJf ../ubuntu-20.04-preinstalled-server-arm64-rpi.rootfs.tar.xz . && cd ..

# Mount the temporary API filesystems
mkdir -p ${chroot_dir}/{proc,sys,run,dev,dev/pts}
mount -t proc /proc ${chroot_dir}/proc
mount -t sysfs /sys ${chroot_dir}/sys
mount -o bind /dev ${chroot_dir}/dev
mount -o bind /dev/pts ${chroot_dir}/dev/pts

# Download and update packages
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

# Developer packages
DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install \
git binutils build-essential bc bison cmake flex libssl-dev device-tree-compiler \
i2c-tools u-boot-tools binfmt-support

# Clean package cache
apt-get -y autoremove && apt-get -y clean && apt-get -y autoclean
EOF

# Auto load g_serial
echo "g_serial" >> ${chroot_dir}/etc/modules

# Enable serial tty
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

systemctl enable serial-getty@ttyGS0.service
EOF

# Terminal dircolors
tee ${chroot_dir}/home/ubuntu/.dircolors ${chroot_dir}/root/.dircolors &>/dev/null << END
# Core formats
RESET 0
DIR 01;34
LINK 01;36
MULTIHARDLINK 00
FIFO 40;33
SOCK 01;35
DOOR 01;35
BLK 40;33;01
CHR 40;33;01
ORPHAN 40;31;01
MISSING 00
SETUID 37;41
SETGID 30;43
CAPABILITY 30;41
STICKY_OTHER_WRITABLE 30;42
OTHER_WRITABLE 34;42
STICKY 37;44
EXEC 01;32
# Archive formats
*.7z 01;31
*.arj 01;31
*.bz2 01;31
*.cpio 01;31
*.gz 01;31
*.lrz 01;31
*.lz 01;31
*.lzma 01;31
*.lzo 01;31
*.rar 01;31
*.s7z 01;31
*.sz 01;31
*.tar 01;31
*.tbz 01;31
*.tgz 01;31
*.warc 01;31
*.WARC 01;31
*.xz 01;31
*.z 01;31
*.zip 01;31
*.zipx 01;31
*.zoo 01;31
*.zpaq 01;31
*.zst 01;31
*.zstd 01;31
*.zz 01;31
# Packaged app formats
.apk 01;31
.ipa 01;31
.deb 01;31
.rpm 01;31
.jad 01;31
.jar 01;31
.ear 01;31
.war 01;31
.cab 01;31
.pak 01;31
.pk3 01;31
.vdf 01;31
.vpk 01;31
.bsp 01;31
.dmg 01;31
.crx 01;31
.xpi 01;31
# Image formats
.bmp 01;35
.dicom 01;35
.tiff 01;35
.tif 01;35
.TIFF 01;35
.cdr 01;35
.flif 01;35
.gif 01;35
.icns 01;35
.ico 01;35
.jpeg 01;35
.JPG 01;35
.jpg 01;35
.nth 01;35
.png 01;35
.psd 01;35
.pxd 01;35
.pxm 01;35
.xpm 01;35
.webp 01;35
.ai 01;35
.eps 01;35
.epsf 01;35
.drw 01;35
.ps 01;35
.svg 01;35
# Audio formats
.3ga 01;35
.S3M 01;35
.aac 01;35
.amr 01;35
.au 01;35
.caf 01;35
.dat 01;35
.dts 01;35
.fcm 01;35
.m4a 01;35
.mod 01;35
.mp3 01;35
.mp4a 01;35
.oga 01;35
.ogg 01;35
.opus 01;35
.s3m 01;35
.sid 01;35
.wma 01;35
.ape 01;35
.aiff 01;35
.cda 01;35
.flac 01;35
.alac 01;35
.mid 01;35
.midi 01;35
.pcm 01;35
.wav 01;35
.wv 01;35
.wvc 01;35
.ogv 01;35
.ogx 01;35
# Video formats
.avi 01;35
.divx 01;35
.IFO 01;35
.m2v 01;35
.m4v 01;35
.mkv 01;35
.MOV 01;35
.mov 01;35
.mp4 01;35
.mpeg 01;35
.mpg 01;35
.ogm 01;35
.rmvb 01;35
.sample 01;35
.wmv 01;35
.3g2 01;35
.3gp 01;35
.gp3 01;35
.webm 01;35
.gp4 01;35
.asf 01;35
.flv 01;35
.ts 01;35
.ogv 01;35
.f4v 01;35
.VOB 01;35
.vob 01;35
# Termcap
TERM ansi
TERM color-xterm
TERM con132x25
TERM con132x30
TERM con132x43
TERM con132x60
TERM con80x25
TERM con80x28
TERM con80x30
TERM con80x43
TERM con80x50
TERM con80x60
TERM cons25
TERM console
TERM cygwin
TERM dtterm
TERM Eterm
TERM eterm-color
TERM gnome
TERM gnome-256color
TERM jfbterm
TERM konsole
TERM kterm
TERM linux
TERM linux-c
TERM mach-color
TERM mlterm
TERM putty
TERM rxvt
TERM rxvt-256color
TERM rxvt-cygwin
TERM rxvt-cygwin-native
TERM rxvt-unicode
TERM rxvt-unicode-256color
TERM rxvt-unicode256
TERM screen
TERM screen-256color
TERM screen-256color-bce
TERM screen-bce
TERM screen-w
TERM screen.linux
TERM screen.rxvt
TERM terminator
TERM vt100
TERM vt220
TERM xterm
TERM xterm-16color
TERM xterm-256color
TERM xterm-88color
TERM xterm-color
TERM xterm-debian
TERM xterm-kitty
END
sed -i 's/#force_color_prompt=yes/color_prompt=yes/g' ${chroot_dir}/home/ubuntu/.bashrc

# Umount the temporary API filesystems
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true

# Tar the entire rootfs
cd ${chroot_dir} && XZ_OPT="-0 -T0" tar -cpJf ../ubuntu-20.04-preinstalled-server-custom-arm64-rpi.rootfs.tar.xz . && cd ..

# Mount the temporary API filesystems
mkdir -p ${chroot_dir}/{proc,sys,run,dev,dev/pts}
mount -t proc /proc ${chroot_dir}/proc
mount -t sysfs /sys ${chroot_dir}/sys
mount -o bind /dev ${chroot_dir}/dev
mount -o bind /dev/pts ${chroot_dir}/dev/pts

# Download and update packages
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

# Mesa packages
DEBIAN_FRONTEND=noninteractive apt-get -y install libegl-mesa0 libgbm1 \
libgl1-mesa-dev libgl1-mesa-dri libglapi-mesa libglx-mesa0 libosmesa6 \
mesa-opencl-icd mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers \
mesa-utils

# Desktop packages
DEBIAN_FRONTEND=noninteractive apt-get -y install ubuntu-desktop

# Clean package cache
apt-get -y autoremove && apt-get -y clean && apt-get -y autoclean
EOF

# Configure custom desktop
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

DEBIAN_FRONTEND=noninteractive apt-get -y install gnome-tweaks gnome-shell-extensions

# Clean package cache
apt-get autoremove -y && apt-get clean -y && apt-get autoclean -y

# Install yaru colors
git clone --depth=1 --progress -b master https://github.com/Jannomag/Yaru-Colors.git

# Copy theme and icons systemwide
mkdir -p /usr/share/{themes,icons}
cp -r Yaru-Colors/Themes/Yaru-Blue /usr/share/themes
cp -r Yaru-Colors/Themes/Yaru-Blue-dark /usr/share/themes
cp -r Yaru-Colors/Themes/Yaru-Blue-light /usr/share/themes
cp -r Yaru-Colors/Icons/Yaru-Blue /usr/share/icons

# Lock screen theme
cp -r Yaru-Colors/Themes/Yaru-Blue/gnome-shell /usr/share/gnome-shell/theme/Yaru-Blue
sed -i 's/Yaru\/gnome-shell.css/Yaru-Blue\/gnome-shell.css/g' /usr/share/gnome-shell/modes/ubuntu.json

# Login screen theme
cp Yaru-Colors/Themes/Yaru-Blue/gnome-shell/yaru-Blue-shell-theme.gresource /usr/share/gnome-shell/gnome-shell-theme.gresource
update-alternatives --set gdm3-theme.gresource /usr/share/gnome-shell/gnome-shell-theme.gresource
rm -rf Yaru-Colors

# Install dash to panel
wget https://extensions.gnome.org/extension-data/dash-to-paneljderose9.github.com.v42.shell-extension.zip

# Install extension systemwide
mkdir -p /usr/share/gnome-shell/extensions/dash-to-panel@jderose9.github.com
unzip -q dash-to-paneljderose9.github.com.v42.shell-extension.zip -d /usr/share/gnome-shell/extensions/dash-to-panel@jderose9.github.com
chmod -R a+rw /usr/share/gnome-shell/extensions/dash-to-panel@jderose9.github.com

# Install gsettings schema
cp /usr/share/gnome-shell/extensions/dash-to-panel@jderose9.github.com/schemas/org.gnome.shell.extensions.dash-to-panel.gschema.xml /usr/share/glib-2.0/schemas
glib-compile-schemas /usr/share/glib-2.0/schemas
rm -rf dash-to-paneljderose9.github.com.v42.shell-extension.zip

# Install arc menu
wget https://extensions.gnome.org/extension-data/arc-menulinxgem33.com.v49.shell-extension.zip

# Install extension systemwide
mkdir -p /usr/share/gnome-shell/extensions/arc-menu@linxgem33.com
unzip -q arc-menulinxgem33.com.v49.shell-extension.zip -d /usr/share/gnome-shell/extensions/arc-menu@linxgem33.com
chmod -R a+rw /usr/share/gnome-shell/extensions/arc-menu@linxgem33.com

# Install gsettings schema
cp /usr/share/gnome-shell/extensions/arc-menu@linxgem33.com/schemas/org.gnome.shell.extensions.arc-menu.gschema.xml /usr/share/glib-2.0/schemas
glib-compile-schemas /usr/share/glib-2.0/schemas
rm -rf arc-menulinxgem33.com.v49.shell-extension.zip

# Favorite apps
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell favorite-apps "['org.gnome.Nautilus.desktop', 'org.gnome.DiskUtility.desktop', 'org.gnome.Terminal.desktop', 'firefox.desktop']"

# Enable extensions
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell enabled-extensions "['user-theme@gnome-shell-extensions.gcampax.github.com', 'dash-to-panel@jderose9.github.com', 'arc-menu@linxgem33.com']"

# Appearance
sudo -u ubuntu dbus-launch gsettings set org.gnome.desktop.interface gtk-theme Yaru-Blue-dark
sudo -u ubuntu dbus-launch gsettings set org.gnome.desktop.interface cursor-theme Yaru-Blue
sudo -u ubuntu dbus-launch gsettings set org.gnome.desktop.interface icon-theme Yaru-Blue

# User theme
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.user-theme name Yaru-dark
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.user-theme name Yaru-Blue

# Arc menu
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.arc-menu button-icon-padding 0
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.arc-menu custom-menu-button-icon-size 38.0
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.arc-menu distro-icon 4
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.arc-menu enable-custom-arc-menu false
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.arc-menu enable-menu-button-arrow false
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.arc-menu menu-button-icon 'Distro_Icon'
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.arc-menu menu-hotkey 'Super_L'
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.arc-menu menu-layout 'Redmond'

# Dash to dock
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock custom-theme-running-dots-color '#208fe9'
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock custom-theme-running-dots-border-color '#208fe9'

# Dash to panel
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.dash-to-panel animate-show-apps true
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.dash-to-panel dot-style-focused 'SOLID'
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.dash-to-panel dot-style-unfocused 'DASHES'
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.dash-to-panel hotkeys-overlay-combo 'TEMPORARILY'
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.dash-to-panel intellihide false
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.dash-to-panel multi-monitors false
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.dash-to-panel panel-position 'BOTTOM'
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.dash-to-panel taskbar-locked false
sudo -u ubuntu dbus-launch gsettings set org.gnome.shell.extensions.dash-to-panel panel-element-positions \
'{"0":[{"element":"showAppsButton","visible":false,"position":"stackedTL"},{"element":"activitiesButton","visible":false,"position":"stackedTL"},\
{"element":"leftBox","visible":true,"position":"stackedTL"},{"element":"taskbar","visible":true,"position":"stackedTL"},\
{"element":"centerBox","visible":true,"position":"stackedBR"},{"element":"rightBox","visible":true,"position":"stackedBR"},\
{"element":"dateMenu","visible":true,"position":"stackedBR"},{"element":"systemMenu","visible":true,"position":"stackedBR"},\
{"element":"desktopButton","visible":true,"position":"stackedBR"}]}'

# Desktop background
wget https://berghauserpont.nl/wp-content/uploads/2020/06/daniel-leone-g30P1zcOzXo-unsplash-scaled.jpg -P /home/ubuntu
sudo -u ubuntu dbus-launch gsettings set org.gnome.desktop.background draw-background false
sudo -u ubuntu dbus-launch gsettings set org.gnome.desktop.background picture-uri file:///home/ubuntu/daniel-leone-g30P1zcOzXo-unsplash-scaled.jpg
sudo -u ubuntu dbus-launch gsettings set org.gnome.desktop.background draw-background true

# Gnome terminal
cat << END >> gnome-terminal-settings.txt
[legacy/profiles:]
default='d4d1730f-f88e-4aa5-b675-e74f29c2702d'
list=['b1dcc9dd-5262-4d8d-a863-c897e6d979b9', 'd4d1730f-f88e-4aa5-b675-e74f29c2702d']

[legacy/profiles:/:d4d1730f-f88e-4aa5-b675-e74f29c2702d]
background-color='rgb(0,0,0)'
bold-is-bright=false
cell-height-scale=1.1000000000000001
foreground-color='rgb(255,255,255)'
palette=['rgb(0,0,0)', 'rgb(255,0,0)', 'rgb(0,255,0)', 'rgb(255,255,0)', 'rgb(63,125,236)', 'rgb(255,0,255)', \
'rgb(0,255,255)', 'rgb(229,229,229)', 'rgb(127,127,127)', 'rgb(205,0,0)', 'rgb(0,205,0)', 'rgb(205,205,0)', \
'rgb(46,96,202)', 'rgb(205,0,205)', 'rgb(0,205,205)', 'rgb(255,255,255)']
use-theme-colors=false
visible-name='XTerm Monospace'
END
sudo -u ubuntu dbus-launch dconf load /org/gnome/terminal/ < gnome-terminal-settings.txt
rm -f gnome-terminal-settings.txt
EOF

# Umount the temporary API filesystems
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true

# Tar the entire rootfs
cd ${chroot_dir} && XZ_OPT="-0 -T0" tar -cpJf ../ubuntu-20.04-preinstalled-desktop-custom-arm64-rpi.rootfs.tar.xz . && cd ..
rm -rf ${chroot_dir} && mkdir -p ${chroot_dir}
cd ${chroot_dir} && tar -xpJf ../ubuntu-20.04-preinstalled-server-arm64-rpi.rootfs.tar.xz . && cd ..

# Mount the temporary API filesystems
mkdir -p ${chroot_dir}/{proc,sys,run,dev,dev/pts}
mount -t proc /proc ${chroot_dir}/proc
mount -t sysfs /sys ${chroot_dir}/sys
mount -o bind /dev ${chroot_dir}/dev
mount -o bind /dev/pts ${chroot_dir}/dev/pts

# Download and update packages
cat << EOF | chroot ${chroot_dir} /bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

# Mesa packages
DEBIAN_FRONTEND=noninteractive apt-get -y install libegl-mesa0 libgbm1 \
libgl1-mesa-dev libgl1-mesa-dri libglapi-mesa libglx-mesa0 libosmesa6 \
mesa-opencl-icd mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers \
mesa-utils

# Desktop packages
DEBIAN_FRONTEND=noninteractive apt-get -y install ubuntu-desktop

# Clean package cache
apt-get -y autoremove && apt-get -y clean && apt-get -y autoclean
EOF

# Umount the temporary API filesystems
umount -lf ${chroot_dir}/dev/pts 2> /dev/null || true
umount -lf ${chroot_dir}/* 2> /dev/null || true

# Tar the entire rootfs
cd ${chroot_dir} && XZ_OPT="-0 -T0" tar -cpJf ../ubuntu-20.04-preinstalled-desktop-arm64-rpi.rootfs.tar.xz . && cd ..
