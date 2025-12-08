#!/usr/bin/env bash
# mkiso-trixie-system-dwm-minimal.sh
# Build Debian Trixie live ISO with minimal environment, build tools, Neovim, Distrobox, and Flatpak.
# Comments are in English.

set -euo pipefail
set -x

LB_DIR="live-build-workdir"
DIST="trixie"
ARCH="amd64"
IMAGE_LABEL="debian-trixie-dwm-tools"

# Packages:
# - build-essential: Necessary for compiling C/C++ programs like dwm.
# - libx11-dev, libxft-dev, libxinerama-dev: dwm dependencies.
# - neovim: The text editor.
# - distrobox, flatpak: The container and application management tools.
# - xinit, xserver-xorg: Minimal X environment to run dwm.
# - firmware-linux, firmware-misc-nonfree: Essential non-free firmware for broad hardware support.
PKGS="build-essential
git
make
libx11-dev
libxft-dev
libxinerama-dev
neovim
distrobox
flatpak
xinit
xserver-xorg
firmware-linux
firmware-misc-nonfree"

# 1) check lb available
if ! command -v lb >/dev/null 2>&1; then
  echo "live-build (lb) not found. Install it first (apt install live-build)."
  exit 1
fi

# 2) clean previous build artifacts
lb clean --purge || true
rm -rf "$LB_DIR"
rm -rf config/archives/*
rm -rf config/includes.chroot/etc/apt/sources.list.d/*
rm -rf config/includes.chroot/var/lib/apt/lists/*
mkdir -p "$LB_DIR"
cd "$LB_DIR"

# 3) lb config
# - Uses "main contrib non-free non-free-firmware" to include firmware and flatpak/distrobox dependencies.
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
  --debootstrap-options="--exclude=xterm" \
  --apt-indices false \
  --apt-source false

# 4) package lists (main)
mkdir -p config/package-lists
printf "%s\n" "$PKGS" > config/package-lists/custom.list.chroot

# 5) Ensure a minimal .xinitrc is present to start dwm automatically
#    (It will be copied to /etc/skel/.xinitrc and used by the live user)
mkdir -p config/includes.chroot/etc/skel
cat > config/includes.chroot/etc/skel/.xinitrc <<'XINIT'
#!/bin/sh
# Start dwm by default
exec dwm
XINIT
chmod +x config/includes.chroot/etc/skel/.xinitrc

# 6) Provide a fallback user 'user' and start X (re-uses part of the original logic)
mkdir -p config/hooks/live-bottom
cat > config/hooks/live-bottom/040-create-user-and-autostart-x.chroot <<'HOOK'
#!/bin/sh
set -e
# create user if not exists and set password 'live'
if ! id -u user >/dev/null 2>&1; then
  useradd -m -s /bin/bash user
  echo 'user:live' | chpasswd
  chage -I -1 -m 0 -M 99999 -E -1 user || true
  # Make sure the live user belongs to 'sudo' group if available (useful for post-install)
  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo user
  fi
fi
# Enable auto-start of X upon login for console TTYs (a very common minimal setup)
# This snippet checks if 'user' is the logged in user on a tty and if .xinitrc exists, then executes startx.
# This assumes the live boot drops to a console login prompt for the 'user'.
cat > /etc/profile.d/autostartx.sh <<'STARTX'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ] && [ "$USER" = "user" ] && [ -f "$HOME/.xinitrc" ]; then
    exec startx
fi
STARTX
chmod +x /etc/profile.d/autostartx.sh
HOOK
chmod +x config/hooks/live-bottom/040-create-user-and-autostart-x.chroot

# 7) Fix apt sources at final image stage so apt works in the live system (re-used)
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

# 8) Minimal cleaning hooks (re-used)
mkdir -p config/hooks/chroot
cat > config/hooks/chroot/001-clean-docs.chroot <<'HOOK'
#!/bin/sh
set -e
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "it*" -exec rm -rf {} + || true
HOOK
chmod +x config/hooks/chroot/001-clean-docs.chroot

# 9) GRUB + isolinux entries: persistence default, toram optional (re-used)
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
label live
  menu label ^Live persistent system
  kernel /live/vmlinuz
  append boot=live persistence quiet splash ---
label toram
  menu label Live (persistent, copy to RAM)
  kernel /live/vmlinuz
  append boot=live persistence toram quiet splash ---
ISOL

# 10) Start the build
echo "Starting lb build (this takes time)..."
lb build

echo "Build finished. The ISO should be in the current directory (live-image-*.iso)."
