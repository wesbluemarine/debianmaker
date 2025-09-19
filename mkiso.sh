#!/usr/bin/env bash
# mkiso-trixie-fix.sh
# Fixed build: avoid BusyBox caused by toram as default, ensure XFCE config applied,
# remove unwanted terminals (xterm), autologin user 'user' with password 'live'.

set -euo pipefail
set -x

LB_DIR="live-build-workdir"
DIST="trixie"
ARCH="amd64"
IMAGE_LABEL="debian-trixie-xfce"

# Packages: core XFCE + appmenu + flatpak etc (no goodies, no xterm)
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

echo "1) Check live-build"
if ! command -v lb >/dev/null 2>&1; then
  echo "Install live-build first: apt install live-build"
  exit 1
fi

echo "2) Full clean"
lb clean --purge || true
rm -rf "$LB_DIR"
rm -rf config/archives/*
rm -rf config/includes.chroot/etc/apt/sources.list.d/*
rm -rf config/includes.chroot/var/lib/apt/lists/*
mkdir -p "$LB_DIR"
cd "$LB_DIR"

echo "3) lb config (NOTE: default uses persistence, NOT toram)"
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

echo "4) sources.list (force Debian Trixie)"
mkdir -p config/includes.chroot/etc/apt
cat > config/includes.chroot/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
rm -f config/includes.chroot/etc/apt/sources.list.d/* || true

echo "5) live-pre: remove stray apt lists"
mkdir -p config/hooks/live-pre
cat > config/hooks/live-pre/000-clean-apt-files.chroot <<'HOOK'
#!/bin/sh
rm -f /etc/apt/sources.list.d/*
HOOK
chmod +x config/hooks/live-pre/000-clean-apt-files.chroot

echo "6) package list"
mkdir -p config/package-lists
printf "%s\n" "$PKGS" > config/package-lists/desktop.list

echo "7) Copy wallpapers if present"
mkdir -p config/includes.chroot/usr/share/backgrounds/debian-custom
if [ -d ../wallpapers ]; then
  cp -a ../wallpapers/* config/includes.chroot/usr/share/backgrounds/debian-custom/ || true
fi

echo "8) Flatpak hook (Flathub)"
mkdir -p config/hooks/live-bottom
cat > config/hooks/live-bottom/020-enable-flatpak.chroot <<'HOOK'
#!/bin/sh
set -e
if command -v flatpak >/dev/null 2>&1; then
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
fi
HOOK
chmod +x config/hooks/live-bottom/020-enable-flatpak.chroot

echo "9) Ensure /etc/environment (append) via live-pre hook"
cat > config/hooks/live-pre/010-append-env.chroot <<'HOOK'
#!/bin/sh
set -e
# append if not already present
grep -qxF 'UBUNTU_MENUPROXY=1' /etc/environment || echo 'UBUNTU_MENUPROXY=1' >> /etc/environment
grep -qxF 'GTK_MODULES=appmenu-gtk-module' /etc/environment || echo 'GTK_MODULES=appmenu-gtk-module' >> /etc/environment
# ensure ~/.local/bin present in PATH for interactive shells (profile.d also added)
grep -qxF 'PATH="$HOME/.local/bin:$PATH"' /etc/environment || echo 'PATH="$HOME/.local/bin:$PATH"' >> /etc/environment
HOOK
chmod +x config/hooks/live-pre/010-append-env.chroot

echo "10) Add default XFCE system-wide and in /etc/skel (so live user gets it)"
# create global defaults (applied for all users)
mkdir -p config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
cat > config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array"><value type="int" value="1"/></property>
  <property name="panels" type="empty">
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="size" type="uint" value="28"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
        <value type="int" value="7"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="applicationsmenu">
      <property name="show-button-title" type="bool" value="true"/>
      <property name="button-title" type="string" value="Applications"/>
      <property name="button-icon" type="string" value=""/>
    </property>
    <property name="plugin-2" type="string" value="appmenu"/>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-4" type="string" value="systray"/>
    <property name="plugin-5" type="string" value="separator">
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-6" type="string" value="clock">
      <property name="digital-time-format" type="string" value="%A, %d %B %Y %I:%M %p"/>
      <property name="mode" type="uint" value="2"/>
    </property>
    <property name="plugin-7" type="string" value="windowmenu"/>
  </property>
</channel>
XML

# also put same config in /etc/skel for the live user
mkdir -p config/includes.chroot/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
cp config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml \
   config/includes.chroot/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml

echo "11) LightDM autologin config"
mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/01-autologin.conf <<'EOF'
[Seat:*]
autologin-user=user
autologin-user-timeout=0
EOF

echo "12) Hook: create user 'user' with password 'live' (live-bottom so it's present in final image)"
mkdir -p config/hooks/live-bottom
cat > config/hooks/live-bottom/010-create-user.chroot <<'HOOK'
#!/bin/sh
set -e
# create user 'user' if not exists and set password
if ! id -u user >/dev/null 2>&1; then
  useradd -m -s /bin/bash user
  echo 'user:live' | chpasswd
  # remove password aging
  chage -I -1 -m 0 -M 99999 -E -1 user || true
fi
HOOK
chmod +x config/hooks/live-bottom/010-create-user.chroot

echo "13) Hook: remove unwanted terminal packages (ensures xterm gone)"
mkdir -p config/hooks/chroot
cat > config/hooks/chroot/000-remove-terminals.chroot <<'HOOK'
#!/bin/sh
set -e
# attempt to remove typical unwanted terminals; ignore failures
apt-get remove --purge -y xterm lxterminal rxvt* || true
apt-get autoremove -y || true
apt-get clean || true
rm -rf /var/lib/apt/lists/* || true
HOOK
chmod +x config/hooks/chroot/000-remove-terminals.chroot

echo "14) Cleanup hook to shrink image (docs, locales, manpages)"
cat > config/hooks/chroot/001-clean-docs.chroot <<'HOOK'
#!/bin/sh
set -e
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "it*" -exec rm -rf {} + || true
HOOK
chmod +x config/hooks/chroot/001-clean-docs.chroot

echo "15) GRUB + ISOLINUX: default persistence, add toram option as second menu"
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

echo "16) Start build"
lb build

echo "Done. If you still drop to BusyBox, try booting the ISO and at the grub menu select the 'Live persistent system' entry (not toram)."
