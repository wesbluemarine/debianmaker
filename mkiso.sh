#!/usr/bin/env bash

set -euo pipefail
set -x  # debug output

LB_DIR="live-build-workdir"
DIST="trixie"
ARCH="amd64"
IMAGE_LABEL="debian-trixie-xfce"

# Main packages
PKGS="xfce4
xfce4-panel
xfce4-appmenu-plugin
xfce4-statusnotifier-plugin
flatpak
suckless-tools
fd-find
wmctrl
xdotool
live-boot
live-config
live-boot-initramfs-tools"

echo "1) Checking host dependencies"
if ! command -v lb >/dev/null 2>&1; then
  echo "live-build (lb) not found: install it first (apt install live-build)."
  exit 1
fi

echo "2) Cleaning previous build and caches"
lb clean --purge || true
rm -rf "$LB_DIR"
rm -rf config/archives/*
rm -rf config/includes.chroot/etc/apt/sources.list.d/*
rm -rf config/includes.chroot/var/lib/apt/lists/*
mkdir -p "$LB_DIR"
cd "$LB_DIR"

echo "3) Configuring live-build for Debian Trixie"
lb config \
  --compress "xz" \
  --distribution "$DIST" \
  --architecture "$ARCH" \
  --archive-areas "main contrib non-free non-free-firmware" \
  --binary-images iso-hybrid \
  --bootappend-live "persistence toram" \
  --debian-installer live \
  --iso-volume "$IMAGE_LABEL" \
  --iso-publisher "Custom Debian Live" \
  --mirror-bootstrap http://deb.debian.org/debian/ \
  --mirror-binary http://deb.debian.org/debian/ \
  --apt-indices false \
  --apt-source false

echo "4) Create correct sources.list in chroot"
mkdir -p config/includes.chroot/etc/apt
cat > config/includes.chroot/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

rm -f config/includes.chroot/etc/apt/sources.list.d/* || true

echo "5) Add live-pre hook to clean residual .list files"
mkdir -p config/hooks/live-pre
cat > config/hooks/live-pre/000-clean-apt-files.chroot <<'HOOK'
#!/bin/sh
rm -f /etc/apt/sources.list.d/*
HOOK
chmod +x config/hooks/live-pre/000-clean-apt-files.chroot

echo "6) Create package list"
mkdir -p config/package-lists
printf "%s\n" "$PKGS" > config/package-lists/desktop.list

echo "7) Include Debian wallpapers (optional)"
mkdir -p config/includes.chroot/usr/share/backgrounds/debian-custom
if [ -d ../wallpapers ]; then
  cp -a ../wallpapers/* config/includes.chroot/usr/share/backgrounds/debian-custom/ || true
fi

echo "8) Hook: enable Flatpak remote Flathub"
mkdir -p config/hooks/live-bottom
cat > config/hooks/live-bottom/020-enable-flatpak.chroot <<'HOOK'
#!/bin/sh
set -e
if command -v flatpak >/dev/null 2>&1; then
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
fi
HOOK
chmod +x config/hooks/live-bottom/020-enable-flatpak.chroot

echo "9) GRUB configuration for persistent live system"
mkdir -p config/includes.binary/boot/grub
cat > config/includes.binary/boot/grub/grub.cfg <<'GRUB'
set default=0
set timeout=10
menuentry "Live persistent system" {
    linux /live/vmlinuz boot=live persistence toram quiet splash ---
    initrd /live/initrd.img
}
menuentry "Live system" {
    linux /live/vmlinuz boot=live quiet splash ---
    initrd /live/initrd.img
}
GRUB

echo "10) isolinux BIOS boot configuration"
mkdir -p config/includes.binary/isolinux
cat > config/includes.binary/isolinux/txt.cfg <<'ISOL'
default vesamenu.c32
timeout 100
label live
  menu label ^Live persistent system
  kernel /live/vmlinuz
  append boot=live persistence toram quiet splash ---
ISOL

echo "11) Hook: append environment variables"
cat > config/hooks/live-pre/010-append-env.chroot <<'HOOK'
#!/bin/sh
set -e
echo 'UBUNTU_MENUPROXY=1' >> /etc/environment
echo 'GTK_MODULES=appmenu-gtk-module' >> /etc/environment
# Ensure .local/bin is in PATH for all users
echo 'PATH="$HOME/.local/bin:$PATH"' >> /etc/environment
HOOK
chmod +x config/hooks/live-pre/010-append-env.chroot

echo "12) XFCE panel default configuration"
mkdir -p config/includes.chroot/etc/xdg/xfce4/panel
cat > config/includes.chroot/etc/xdg/xfce4/panel/default.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=8;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="size" type="uint" value="28"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/> <!-- Application Menu -->
        <value type="int" value="2"/> <!-- Appmenu Plugin -->
        <value type="int" value="3"/> <!-- Transparent Separator -->
        <value type="int" value="4"/> <!-- Status Tray -->
        <value type="int" value="5"/> <!-- Transparent Separator -->
        <value type="int" value="6"/> <!-- Clock -->
        <value type="int" value="7"/> <!-- Window Menu -->
      </property>
    </property>
  </property>

  <property name="plugins" type="map">
    <property name="plugin-1" type="string" value="applicationsmenu">
      <property name="button-label" type="string" value="Applications"/>
      <property name="show-button-title" type="bool" value="true"/>
      <property name="show-button-icon" type="bool" value="false"/>
    </property>

    <property name="plugin-2" type="string" value="appmenu"/>

    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>

    <property name="plugin-4" type="string" value="statusnotifier"/>

    <property name="plugin-5" type="string" value="separator">
      <property name="expand" type="bool" value="false"/>
      <property name="style" type="uint" value="0"/>
    </property>

    <property name="plugin-6" type="string" value="clock">
      <property name="digital-time-format" type="string" value="%A, %e %B %Y %I:%M %p"/>
      <property name="mode" type="uint" value="2"/>
    </property>

    <property name="plugin-7" type="string" value="windowmenu"/>
  </property>
</channel>
XML

echo "13) Start build (lb build). This may take time."
lb build

echo "Build completed. ISO should be in the current directory (live-image-amd64.hybrid.iso or similar)."
echo "Done."
