#!/usr/bin/env bash
# Build Debian live ISO with minimal environment.

set -euo pipefail
set -x

LB_DIR="live-build-workdir"
DIST="trixie"
ARCH="amd64"
IMAGE_LABEL="debian-trixie-tools"
# Generate timestamp: YearMonthDayHourMinute
TIMESTAMP=$(date +"%Y%m%d%H%M")

# 1) Updated Package List (Runtime)
PKGS="dbus-x11
distrobox
firmware-linux
firmware-misc-nonfree
git
pipewire-audio
x11-xserver-utils
xfonts-terminus
xinit
xserver-xorg
libid3tag0
libimlib2t64
libobrender32v5
libobt2v5
obconf
scrot"

# 2) check lb available
if ! command -v lb >/dev/null 2>&1; then
  echo "live-build (lb) not found. Install it first (apt install live-build)."
  exit 1
fi

# 3) clean previous build artifacts
lb clean --purge || true
rm -rf "$LB_DIR"
rm -rf config/archives/*
rm -rf config/includes.chroot/etc/apt/sources.list.d/*
rm -rf config/includes.chroot/var/lib/apt/lists/*
mkdir -p "$LB_DIR"
cd "$LB_DIR"

# 4) lb config
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

# 5) package lists (main)
mkdir -p config/package-lists
printf "%s\n" "$PKGS" > config/package-lists/custom.list.chroot

# 6) HOOK: Compile Patched Openbox using build-dep
mkdir -p config/hooks/normal
cat << 'EOF' > config/hooks/normal/0500-compile-openbox.chroot
#!/bin/sh
set -e

# Temporarily enable deb-src to use 'apt build-dep'
echo "deb-src http://deb.debian.org/debian trixie main contrib non-free non-free-firmware" > /etc/apt/sources.list.d/sources-src.list

apt-get update

# Install build-essential, git, curl and all openbox build dependencies
apt-get install -y --no-install-recommends build-essential git curl
apt-get build-dep -y openbox

# Clone Openbox Source
cd /tmp
git clone https://github.com/danakj/openbox.git
cd openbox

# Download and Apply the Window-Snap Patch
curl -L https://raw.githubusercontent.com/wesbluemarine/openbox-window-snap/master/openbox-3.6.1-patch.diff -o snap.patch
patch -p1 < snap.patch

# Build and Install
./bootstrap
./configure --prefix=/usr --sysconfdir=/etc
make
make install

# Cleanup: Remove source list, build-deps, and temporary files
rm /etc/apt/sources.list.d/sources-src.list
apt-get update
# We use 'markauto' logic or purge build-essential/git to stay minimal
apt-get purge -y build-essential git curl
apt-get autoremove -y
apt-get clean

cd /
rm -rf /tmp/openbox
EOF
chmod +x config/hooks/normal/0500-compile-openbox.chroot

# 7) Provide a fallback user 'user' and start X
mkdir -p config/hooks/live-bottom
cat > config/hooks/live-bottom/040-create-user-and-autostart-x.chroot <<'HOOK'
#!/bin/sh
set -e
if ! id -u user >/dev/null 2>&1; then
  useradd -m -s /bin/bash user
  echo 'user:live' | chpasswd
  chage -I -1 -m 0 -M 99999 -E -1 user || true
  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo user
  fi
fi
cat > /etc/profile.d/autostartx.sh <<'STARTX'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ] && [ "$USER" = "user" ] && [ -f "$HOME/.xinitrc" ]; then
    startx
fi
STARTX
chmod +x /etc/profile.d/autostartx.sh
HOOK
chmod +x config/hooks/live-bottom/040-create-user-and-autostart-x.chroot

# 8) Fix apt sources
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

# 9) Minimal cleaning hooks
mkdir -p config/hooks/chroot
cat > config/hooks/chroot/001-clean-docs.chroot <<'HOOK'
#!/bin/sh
set -e
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "it*" -exec rm -rf {} + || true
HOOK
chmod +x config/hooks/chroot/001-clean-docs.chroot

# 10) GRUB + isolinux entries
mkdir -p config/includes.binary/boot/grub
cat > config/includes.binary/boot/grub/grub.cfg <<'GRUB'
set default=0
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

# 11) Start the build
echo "Starting lb build..."
lb build

# 12) Rename the output ISO
if ls live-image-*.iso 1> /dev/null 2>&1; then
    mv live-image-*.iso "${TIMESTAMP}.iso"
    echo "Build finished. ISO renamed to: ${TIMESTAMP}.iso"
else
    echo "Error: ISO file not found."
fi
