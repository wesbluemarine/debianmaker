#!/usr/bin/env bash
# mkiso-trixie-system-xfce.sh
# Build Debian Trixie live ISO with XFCE, Flatpak and system-wide XFCE panel config.

set -euo pipefail
set -x

LB_DIR="live-build-workdir"
DIST="trixie"
ARCH="amd64"
IMAGE_LABEL="debian-trixie-xfce"

# Packages
PKGS="task-xfce-desktop
lightdm
lightdm-gtk-greeter
xfce4-terminal
xfce4-appmenu-plugin
xfce4-indicator-plugin
distrobox
flatpak
suckless-tools"

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

# 5) Provide a fallback copy into /etc/skel only if you want new users to have it by default
#    (we avoid copying to existing home; /etc/skel is used when a user is created)
mkdir -p config/includes.chroot/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
# La riga seguente è commentata perché il file sorgente non viene creato altrove nello script
# cp config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml \
#    config/includes.chroot/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml


# 6) Fix apt sources at final image stage so apt works in the live system
mkdir -p config/hooks/live-bottom # <--- FIX per l'errore "No such file or directory"
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

# 7) Create LightDM autologin config via includes (static file)
mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/60-autologin.conf <<'LF'
[Seat:*]
autologin-user=user
autologin-user-timeout=0
LF

# 8) Create user 'user' with password 'live' in final image (live-bottom hook)
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

# 9) Remove unwanted terminal packages inside chroot (extra safety)
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

# 10) Clean docs/locales to shrink image (safe)
cat > config/hooks/chroot/001-clean-docs.chroot <<'HOOK'
#!/bin/sh
set -e
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* || true
# keep en and it locales only (adjust if you need more)
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name "en*" ! -name "it*" -exec rm -rf {} + || true
HOOK
chmod +x config/hooks/chroot/001-clean-docs.chroot

# 11) GRUB + isolinux entries: persistence default, toram optional
mkdir -p config/includes.binary/boot/grub
cat > config/includes.binary/boot/grub/grub.cfg <<'GRUB'
set default=0
set timeout=8
menuentry "Live persistent system" {
    linux /live/vmlinuz boot=live persistence quiet splash ---
    initrd /live/initrd.img
}
menuentry "Live
