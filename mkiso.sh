#!/usr/bin/env bash

set -euo pipefail
set -x

LB_DIR="live-build-workdir"
DIST="trixie"
ARCH="amd64"
IMAGE_LABEL="debian-trixie-xfce"

PKGS="xfce4
xfce4-appmenu-plugin
flatpak
suckless-tools
fd-find
wmctrl
xdotool
live-boot
live-config
live-boot-initramfs-tools"

echo "1) Check live-build"
if ! command -v lb >/dev/null 2>&1; then
  echo "Install live-build first: sudo apt install live-build"
  exit 1
fi

echo "2) Cleanup"
lb clean --purge || true
rm -rf "$LB_DIR"
mkdir -p "$LB_DIR"
cd "$LB_DIR"

echo "3) Configure live-build"
lb config \
  --compress xz \
  --compression-level 9 \
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

echo "4) sources.list"
mkdir -p config/includes.chroot/etc/apt
cat > config/includes.chroot/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

echo "5) Hook to clean .list files"
mkdir -p config/hooks/live-pre
cat > config/hooks/live-pre/000-clean-apt-files.chroot <<'HOOK'
#!/bin/sh
rm -f /etc/apt/sources.list.d/*
HOOK
chmod +x config/hooks/live-pre/000-clean-apt-files.chroot

echo "6) Package list"
mkdir -p config/package-lists
printf "%s\n" "$PKGS" > config/package-lists/desktop.list

echo "7) XFCE panel defaults"
mkdir -p config/includes.chroot/etc/xdg/xfce4/panel
mkdir -p config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml

# Default panel layout (top, single bar)
cat > config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="size" type="uint" value="32"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
      </property>
    </property>
  </property>

  <!-- Application menu -->
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu">
      <property name="button-title" type="string" value="Applications"/>
      <property name="button-icon" type="string" value=""/>
      <property name="show-button-title" type="bool" value="true"/>
    </property>

    <!-- AppMenu -->
    <property name="plugin-2" type="string" value="appmenu"/>

    <!-- Separator expand -->
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>

    <!-- Status Tray -->
    <property name="plugin-4" type="string" value="systray"/>

    <!-- Separator -->
    <property name="plugin-5" type="string" value="separator">
      <property name="style" type="uint" value="0"/>
    </property>

    <!-- Clock -->
    <property name="plugin-6" type="string" value="clock">
      <property name="digital-format" type="string" value="%A, %d %B %Y %I:%M %p"/>
    </property>

    <!-- Window Menu -->
    <property name="plugin-7" type="string" value="windowmenu"/>
  </property>
</channel>
EOF

echo "8) Flatpak hook"
mkdir -p config/hooks/live-bottom
cat > config/hooks/live-bottom/020-enable-flatpak.chroot <<'HOOK'
#!/bin/sh
if command -v flatpak >/dev/null 2>&1; then
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
fi
HOOK
chmod +x config/hooks/live-bottom/020-enable-flatpak.chroot

echo "9) Cleanup hook"
cat > config/hooks/live-bottom/030-cleanup.chroot <<'HOOK'
#!/bin/sh
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /usr/share/doc/*
rm -rf /usr/share/man/*
rm -rf /usr/share/info/*
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "it*" -exec rm -rf {} +
HOOK
chmod +x config/hooks/live-bottom/030-cleanup.chroot

echo "10) Environment vars"
mkdir -p config/includes.chroot/etc
cat >> config/includes.chroot/etc/environment <<'EOF'
UBUNTU_MENUPROXY=1
GTK_MODULES=appmenu-gtk-module
EOF

echo "11) Add ~/.local/bin to PATH"
mkdir -p config/includes.chroot/etc/skel/.local/bin
cat > config/includes.chroot/etc/profile.d/10-local-bin.sh <<'EOF'
if [ -d "$HOME/.local/bin" ] && ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
  export PATH="$HOME/.local/bin:$PATH"
fi
EOF

echo "12) Bootloader configs"
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

mkdir -p config/includes.binary/isolinux
cat > config/includes.binary/isolinux/txt.cfg <<'ISOL'
default vesamenu.c32
timeout 100
label live
  menu label ^Live persistent system
  kernel /live/vmlinuz
  append boot=live persistence toram quiet splash ---
ISOL

echo "13) Build ISO"
lb build
