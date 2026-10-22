#!/usr/bin/env bash
# Build Debian live ISO with minimal environment.

set -euo pipefail
set -x

LB_DIR="live-build-workdir"
DIST="trixie"
ARCH="amd64"
IMAGE_LABEL="debian-trixie-tools"
TIMESTAMP=$(date +"%Y%m%d%H%M")

# 1) Runtime Packages
PKGS="linux-image-amd64
dbus-x11
distrobox
firmware-linux
#firmware-misc-nonfree
libavcodec-extra
libopengl0
libid3tag0
libimlib2t64
libsdl2-2.0-0
scrot
pipewire-audio
x11-xserver-utils
xfonts-terminus
xinit
xserver-xorg
wmaker
tzdata" # Timezone management

# 2) Check if live-build is available
if ! command -v lb >/dev/null 2>&1; then
  echo "live-build (lb) not found. Install it first (apt install live-build)."
  exit 1
fi

# 3) Clean previous build artifacts
lb clean --purge || true
rm -rf "$LB_DIR"
rm -rf config/archives/*
rm -rf config/includes.chroot/etc/apt/sources.list.d/*
rm -rf config/includes.chroot/var/lib/apt/lists/*
mkdir -p "$LB_DIR"
cd "$LB_DIR"

# 4) Configure live-build options
lb config \
  --compress xz \
  --distribution "$DIST" \
  --architecture "$ARCH" \
  --archive-areas "main contrib non-free non-free-firmware" \
  --binary-images iso-hybrid \
  --bootappend-live "persistence" \
  --debian-installer live \
  --iso-volume "$IMAGE_LABEL" \
  --iso-publisher "Custom Debian Live" \
  --mirror-bootstrap http://deb.debian.org/debian/ \
  --mirror-binary http://deb.debian.org/debian/ \
  --apt-indices false \
  --apt-source false

# 5) Define package lists
mkdir -p config/package-lists
printf "%s\n" "$PKGS" > config/package-lists/custom.list.chroot

# 6) User creation, Autostart and Timezone setup
mkdir -p config/hooks/live-bottom
cat > config/hooks/live-bottom/040-create-user-and-autostart-x.chroot <<'HOOK'
#!/bin/sh
set -e

# Set Timezone to Europe/Rome non-interactively without systemd-sync
ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime
echo "Europe/Rome" > /etc/timezone

# Create default live user if not exists
if ! id -u user >/dev/null 2>&1; then
  useradd -m -s /bin/bash user
  echo 'user:live' | chpasswd
  chage -I -1 -m 0 -M 99999 -E -1 user || true
  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo user
  fi
fi

# Trigger startx on TTY1 login, only if the user has a ~/.xinitrc
# (otherwise X would exit immediately) and only once per boot
# (avoids respawn loops if X dies or the session ends).
cat > /etc/profile.d/autostartx.sh <<'STARTX'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ] && [ "$USER" = "user" ] \
   && [ -f "$HOME/.xinitrc" ] && [ ! -e /tmp/.startx-done ]; then
    touch /tmp/.startx-done
    startx
fi
STARTX
chmod +x /etc/profile.d/autostartx.sh
HOOK
chmod +x config/hooks/live-bottom/040-create-user-and-autostart-x.chroot

# 7) Configure APT sources for the live system
cat > config/hooks/live-bottom/030-fix-sources.chroot <<'HOOK'
#!/bin/sh
set -e
cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
rm -f /etc/apt/sources.list.d/* || true
apt-get update || true
HOOK
chmod +x config/hooks/live-bottom/030-fix-sources.chroot

# 8) Minimalize image size by removing docs and unused locales
mkdir -p config/hooks/chroot
cat > config/hooks/chroot/001-clean-docs.chroot <<'HOOK'
#!/bin/sh
set -e
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "it*" -exec rm -rf {} + || true
HOOK
chmod +x config/hooks/chroot/001-clean-docs.chroot

# 9) Bootloader Configuration (GRUB and ISOLINUX)
mkdir -p config/includes.binary/boot/grub
cat > config/includes.binary/boot/grub/grub.cfg <<'GRUB'
set default=1
set timeout=8
menuentry "Live persistent system" {
    linux /live/__KERNEL__ boot=live persistence quiet splash ---
    initrd /live/__INITRD__
}
menuentry "Live persistent system (toram)" {
    linux /live/__KERNEL__ boot=live persistence toram quiet splash ---
    initrd /live/__INITRD__
}
GRUB

mkdir -p config/includes.binary/isolinux
cat > config/includes.binary/isolinux/txt.cfg <<'ISOL'
default vesamenu.c32
timeout 100
label toram
  menu label Live (persistent, copy to RAM)
  kernel /live/__KERNEL__
  append boot=live persistence toram quiet splash ---
label live
  menu label ^Live persistent system
  kernel /live/__KERNEL__
  append boot=live persistence quiet splash ---
ISOL

# live-build names the kernel/initrd with the version (e.g. vmlinuz-6.12.x-amd64),
# so the fixed names above would not be found at boot. This hook runs on the
# binary tree after includes.binary are copied and puts in the real file names.
mkdir -p config/hooks/normal
cat > config/hooks/normal/0900-fix-kernel-names.binary <<'HOOK'
#!/bin/sh
set -e
[ -d binary/live ] && cd binary
KERNEL=$(basename "$(ls live/vmlinuz* | head -n1)")
INITRD=$(basename "$(ls live/initrd.img* | head -n1)")
for f in boot/grub/grub.cfg isolinux/txt.cfg; do
  [ -f "$f" ] && sed -i "s|__KERNEL__|$KERNEL|g; s|__INITRD__|$INITRD|g" "$f"
done
exit 0
HOOK
chmod +x config/hooks/normal/0900-fix-kernel-names.binary

# 10) Execute build
echo "Starting lb build..."
lb build

# 11) Output management
if ls live-image-*.iso 1> /dev/null 2>&1; then
    mv live-image-*.iso "${TIMESTAMP}.iso"
    echo "Build finished: ${TIMESTAMP}.iso"
else
    echo "Error: ISO file not found."
fi
