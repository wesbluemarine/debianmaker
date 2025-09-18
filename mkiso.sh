#!/usr/bin/env bash

set -euo pipefail
set -x

LB_DIR="live-build-workdir"
DIST="trixie"
ARCH="amd64"
IMAGE_LABEL="debian-trixie-xfce"

# Pacchetti principali
PKGS="xfce4
xfce4-appmenu-plugin
lightdm
flatpak
suckless-tools
fd-find
wmctrl
xdotool
live-boot
live-config
live-boot-initramfs-tools"

echo "1) Check dependencies"
if ! command -v lb >/dev/null 2>&1; then
  echo "Please install live-build (apt install live-build)."
  exit 1
fi

echo "2) Clean previous build"
lb clean --purge || true
rm -rf "$LB_DIR"
mkdir -p "$LB_DIR"
cd "$LB_DIR"

echo "3) Configure live-build"
lb config \
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
  --debootstrap-options "--exclude=xterm" \
  --apt-indices false \
  --apt-source false

echo "4) sources.list"
mkdir -p config/includes.chroot/etc/apt
cat > config/includes.chroot/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

echo "5) Package list"
mkdir -p config/package-lists
printf "%s\n" $PKGS > config/package-lists/desktop.list

echo "6) Force XFCE config into /etc/skel"
mkdir -p config/includes.chroot/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
cat > config/includes.chroot/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml <<'PANEL'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array">
    <value type="int" value="1"/>
  </property>
  <property name="panels" type="empty">
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="size" type="uint" value="24"/>
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
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="applicationsmenu"/>
    <property name="plugin-2" type="string" value="appmenu"/>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
    </property>
    <property name="plugin-4" type="string" value="systray"/>
    <property name="plugin-5" type="string" value="separator"/>
    <property name="plugin-6" type="string" value="clock"/>
  </property>
</channel>
PANEL

echo "7) LightDM autologin config"
mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/01-autologin.conf <<'EOF'
[Seat:*]
autologin-user=user
autologin-user-timeout=0
EOF

echo "8) Hook: ensure user/password"
mkdir -p config/hooks/live-bottom
cat > config/hooks/live-bottom/010-create-user.chroot <<'HOOK'
#!/bin/sh
set -e
if ! id -u user >/dev/null 2>&1; then
    useradd -m -s /bin/bash user
    echo "user:live" | chpasswd
    adduser user sudo || true
fi
HOOK
chmod +x config/hooks/live-bottom/010-create-user.chroot

echo "9) Environment vars"
mkdir -p config/includes.chroot/etc
cat >> config/includes.chroot/etc/environment <<'EOF'
UBUNTU_MENUPROXY=1
GTK_MODULES=appmenu-gtk-module
PATH="$HOME/.local/bin:$PATH"
EOF

echo "10) Build ISO"
lb build
