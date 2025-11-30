#!/usr/bin/env bash
# mkiso-trixie-system-xfce.sh
# Build Debian Trixie live ISO with XFCE, Flatpak and system-wide XFCE panel config.
# Comments are in English.

set -euo pipefail
set -x

LB_DIR="live-build-workdir"
DIST="trixie"
ARCH="amd64"
IMAGE_LABEL="debian-trixie-xfce"

# Packages: no distrobox, no xterm; xfce4 core + terminal + appmenu + indicator + flatpak
PKGS="task-xfce-desktop
lightdm
lightdm-gtk-greeter
xfce4-terminal
xfce4-appmenu-plugin
xfce4-indicator-plugin
flatpak"

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
# - do NOT make toram default (use persistence as default) to avoid copying entire iso to RAM by default
# - exclude xterm at bootstrap time to reduce chance it's pulled in
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

# Also try to explicitly blacklist xterm removal if somehow present:
mkdir -p config/package-lists
cat > config/package-lists/remove.list.chroot <<'EOF'
xterm-
EOF

# 5) Ensure system-wide XFCE configuration (put in /etc/xdg so it's global)
#    This avoids relying on per-home copying; XFCE will use system defaults from /etc/xdg.
mkdir -p config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
cat > config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array">
    <value type="int" value="1"/>
  </property>

  <property name="panels" type="empty">
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
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
      <property name="show-button-icon" type="bool" value="false"/>
    </property>

    <property name="plugin-2" type="string" value="appmenu"/>

    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>

    <property name="plugin-4" type="string" value="systray"/>

    <property name="plugin-5" type="string" value="separator">
      <property name="expand" type="bool" value="false"/>
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

# 6) Provide a fallback copy into /etc/skel only if you want new users to have it by default
#    (we avoid copying to existing home; /etc/skel is used when a user is created)
mkdir -p config/includes.chroot/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
cp config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml \
   config/includes.chroot/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml

# 7) Ensure AppMenu environment vars are present at runtime (append /etc/environment via hook)
mkdir -p config/hooks/live-bottom
cat > config/hooks/live-bottom/020-environment.chroot <<'HOOK'
#!/bin/sh
set -e
# append variables only if not present (idempotent)
grep -qxF 'UBUNTU_MENUPROXY=1' /etc/environment || echo 'UBUNTU_MENUPROXY=1' >> /etc/environment
grep -qxF 'GTK_MODULES=appmenu-gtk-module' /etc/environment || echo 'GTK_MODULES=appmenu-gtk-module' >> /etc/environment
# ensure user-local bin in PATH (keeps compatibility)
grep -qxF 'PATH="$HOME/.local/bin:$PATH"' /etc/environment || echo 'PATH="$HOME/.local/bin:$PATH"' >> /etc/environment
HOOK
chmod +x config/hooks/live-bottom/020-environment.chroot

# 8) Fix apt sources at final image stage so apt works in the live system
cat > config/hooks/live-bottom/030-fix-sources.chroot <<'HOOK'
#!/bin/sh
set -e
cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
# remove stray .list files
rm -f /etc/apt/sources.list.d/* || true
# update apt lists (ignore failures, but usually should succeed)
apt-get update || true
HOOK
chmod +x config/hooks/live-bottom/030-fix-sources.chroot

# 9) Create LightDM autologin config via includes (static file)
mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/60-autologin.conf <<'LF'
[Seat:*]
autologin-user=user
autologin-user-timeout=0
LF

# 10) Create user 'user' with password 'live' in final image (live-bottom hook)
cat > config/hooks/live-bottom/040-create-user.chroot <<'HOOK'
#!/bin/sh
set -e
# create user if not exists and set password
if ! id -u user >/dev/null 2>&1; then
  useradd -m -s /bin/bash user
  echo 'user:live' | chpasswd
  # relax password aging
  chage -I -1 -m 0 -M 99999 -E -1 user || true
fi
HOOK
chmod +x config/hooks/live-bottom/040-create-user.chroot

# 11) Remove unwanted terminal packages inside chroot (extra safety)
mkdir -p config/hooks/chroot
cat > config/hooks/chroot/000-remove-terminals.chroot <<'HOOK'
#!/bin/sh
set -e
# try to remove common terminal packages we don't want; ignore errors
apt-get remove --purge -y xterm lxterminal rxvt* || true
apt-get autoremove -y || true
apt-get clean || true
rm -rf /var/lib/apt/lists/* || true
HOOK
chmod +x config/hooks/chroot/000-remove-terminals.chroot

# 12) Clean docs/locales to shrink image (safe)
cat > config/hooks/chroot/001-clean-docs.chroot <<'HOOK'
#!/bin/sh
set -e
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
# keep en and it locales only (adjust if you need more)
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "it*" -exec rm -rf {} + || true
HOOK
chmod +x config/hooks/chroot/001-clean-docs.chroot

# 13) GRUB + isolinux entries: persistence default, toram optional
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

# 14) Optional: include wallpapers if present in repo ../wallpapers
mkdir -p config/includes.chroot/usr/share/backgrounds/debian-custom
if [ -d ../wallpapers ]; then
  cp -a ../wallpapers/* config/includes.chroot/usr/share/backgrounds/debian-custom/ || true
fi

# 15) Start the build
echo "Starting lb build (this takes time)..."
lb build

echo "Build finished. The ISO should be in the current directory (live-image-*.iso)."
