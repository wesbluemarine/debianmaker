#!/usr/bin/env bash
# Build Debian live ISO with custom patched Openbox
# Optimized for a minimal environment without build-essential in the final image.

set -euo pipefail
set -x

LB_DIR="live-build-workdir"
DIST="trixie"
ARCH="amd64"
IMAGE_LABEL="debian-trixie-openbox-custom"
TIMESTAMP=$(date +"%Y%m%d%H%M")

# 1. Runtime Packages
# Includes dependencies identified from the terminal screenshot.
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

if ! command -v lb >/dev/null 2>&1; then
  echo "live-build (lb) not found. Install it first (apt install live-build)."
  exit 1
fi

lb clean --purge || true
rm -rf "$LB_DIR"
mkdir -p "$LB_DIR"
cd "$LB_DIR"

# 2. Configure live-build
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

# 3. Create runtime package list
mkdir -p config/package-lists
printf "%s\n" "$PKGS" > config/package-lists/custom.list.chroot

# 4. Create Chroot Hook for Openbox Compilation
# This script runs inside the build environment and self-cleans.
mkdir -p config/hooks/normal
cat << 'EOF' > config/hooks/normal/0500-compile-openbox.chroot
#!/bin/sh
set -e

# Temporary build dependencies
BUILD_DEPS="build-essential git automake libtool pkg-config curl \
    libxml2-dev libglib2.0-dev libpango1.0-dev \
    libxft-dev libxinerama-dev libxrandr-dev \
    libxcursor-dev libsm-dev libimlib2-dev liblibrsvg2-dev"

apt-get update
apt-get install -y --no-install-recommends $BUILD_DEPS

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

# Cleanup: Remove source code and build-only packages
cd /
rm -rf /tmp/openbox
apt-get purge -y $BUILD_DEPS
apt-get autoremove -y
apt-get clean
EOF

chmod +x config/hooks/normal/0500-compile-openbox.chroot

# 5. Build the ISO
# To start the build, run:
# sudo lb build
