#!/usr/bin/env bash
# Build Debian live ISO with minimal environment and custom Openbox.

set -euo pipefail
set -x

LB_DIR="live-build-workdir"
DIST="trixie"
ARCH="amd64"
IMAGE_LABEL="debian-trixie-tools"
TIMESTAMP=$(date +"%Y%m%d%H%M")

# 1) Runtime Packages
PKGS="dbus-x11
distrobox
firmware-linux
#firmware-misc-nonfree
libavcodec-extra
libopengl0
libid3tag0
libimlib2t64
libobrender32v5
libobt2v5
libsdl2-2.0-0
scrot
pipewire-audio
x11-xserver-utils
xfonts-terminus
xinit
xserver-xorg
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

# 6) HOOK: Compile Patched Openbox
mkdir -p config/hooks/normal
cat << 'EOF' > config/hooks/normal/0500-compile-openbox.chroot
#!/bin/sh
set -e

# Temporarily enable deb-src for building
echo "deb-src http://deb.debian.org/debian trixie main contrib non-free non-free-firmware" > /etc/apt/sources.list.d/sources-src.list

apt-get update
# Install build tools and docbook-to-man
apt-get install -y --no-install-recommends build-essential git curl ca-certificates docbook-to-man

# Install build dependencies for openbox
apt-get build-dep -y openbox

cd /tmp
git clone https://github.com/danakj/openbox.git
cd openbox

# Download and apply window-snapping patch
curl -f -L https://raw.githubusercontent.com/wesbluemarine/openbox-window-snap/refs/heads/master/openbox-window-snap.diff -o snap.patch
patch -p1 < snap.patch

# Build
./bootstrap
./configure --prefix=/usr --sysconfdir=/etc
make -j$(nproc)

# --- Minimal Debian Package ---
mkdir -p /tmp/openbox-pkg/DEBIAN
make install DESTDIR=/tmp/openbox-pkg

# Create file control package
cat <<DEBCONTROL > /tmp/openbox-pkg/DEBIAN/control
Package: openbox
Version: 3.6.1-patched
Section: x11
Priority: optional
Architecture: amd64
Maintainer: Custom-Build
Description: Openbox patched with window-snapping.
Provides: openbox
Conflicts: openbox
DEBCONTROL

# Build and install il .deb
dpkg-deb --build /tmp/openbox-pkg /tmp/openbox-patched.deb
dpkg -i /tmp/openbox-patched.deb
# -----------------------------------------------------------------

# Cleanup build-only dependencies and source files
rm /etc/apt/sources.list.d/sources-src.list
apt-get update
apt-get purge -y build-essential git curl docbook-to-man
apt-get autoremove -y
apt-get clean
cd /
rm -rf /tmp/openbox /tmp/openbox-pkg /tmp/openbox-patched.deb
EOF
chmod +x config/hooks/normal/0500-compile-openbox.chroot

# 7) User creation, .xinitrc, Autostart and Timezone setup
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

# Create .xinitrc to ensure Openbox is the main session process
cat > /home/user/.xinitrc <<'XINIT'
#!/bin/sh
# Use exec to replace the xinit process with openbox-session
exec openbox-session
XINIT
chown user:user /home/user/.xinitrc
chmod +x /home/user/.xinitrc

# Trigger startx on TTY1 login. 
# Using 'exec' ensures that when X exits, the shell session ends immediately.
cat > /etc/profile.d/autostartx.sh <<'STARTX'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ] && [ "$USER" = "user" ]; then
    startx
fi
STARTX
chmod +x /etc/profile.d/autostartx.sh
HOOK
chmod +x config/hooks/live-bottom/040-create-user-and-autostart-x.chroot

# 8) Configure APT sources for the live system
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

# 9) Minimalize image size by removing docs and unused locales
mkdir -p config/hooks/chroot
cat > config/hooks/chroot/001-clean-docs.chroot <<'HOOK'
#!/bin/sh
set -e
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "it*" -exec rm -rf {} + || true
HOOK
chmod +x config/hooks/chroot/001-clean-docs.chroot

# 10) Bootloader Configuration (GRUB and ISOLINUX)
mkdir -p config/includes.binary/boot/grub
cat > config/includes.binary/boot/grub/grub.cfg <<'GRUB'
set default=1
set timeout=8
menuentry "Live persistent system" {
    linux /live/vmlinuz boot=live persistence quiet splash ---
    initrd /live/initrd.img
}
menuentry "Live persistent system (toram)" {
    linux /live/vmlinuz boot=live persistence toram quiet splash ---
    initrd /live/initrd.img
}
GRUB

mkdir -p config/includes.binary/isolinux
cat > config/includes.binary/isolinux/txt.cfg <<'ISOL'
default vesamenu.c32
timeout 100
label toram
  menu label Live (persistent, copy to RAM)
  kernel /live/vmlinuz
  append boot=live persistence toram quiet splash ---
label live
  menu label ^Live persistent system
  kernel /live/vmlinuz
  append boot=live persistence quiet splash ---
ISOL

# 11) Execute build
echo "Starting lb build..."
lb build

# 12) Output management
if ls live-image-*.iso 1> /dev/null 2>&1; then
    mv live-image-*.iso "${TIMESTAMP}.iso"
    echo "Build finished: ${TIMESTAMP}.iso"
else
    echo "Error: ISO file not found."
fi
