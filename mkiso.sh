#!/bin/bash
set -euo pipefail

# ============================================================
#  Build script for Debian Live ISO with WindowMaker
#  UEFI only, Zstandard-compressed filesystem
# ============================================================

TOPDIR="$(pwd)"
GEN_DIR="$TOPDIR/generated.x86"
OUTDIR="$TOPDIR/output"

DATE=$(date +%Y%m%d)
ISONAME="Debian-WMaker-UEFI-${DATE}.iso"

# ============================================================
# 1. Install build dependencies
# ============================================================
echo "[*] Installing build dependencies..."
sudo apt update
sudo apt install -y --no-install-recommends \
  debootstrap xorriso squashfs-tools \
  grub-efi-amd64-bin mtools dosfstools \
  wget git make gcc g++ fakeroot devscripts lintian \
  passwd xorg xserver-xorg-core xserver-xorg-video-all \
  x11-xserver-utils x11-xkb-utils x11-utils \
  xinit thunar distrobox nsxiv xarchiver \
  wmaker wmtime zenity

# ============================================================
# 2. Prepare build directories
# ============================================================
mkdir -p "$GEN_DIR" "$OUTDIR"

# ============================================================
# 3. Bootstrap minimal Debian
# ============================================================
echo "[*] Creating minimal rootfs..."
sudo debootstrap --arch=amd64 trixie "$GEN_DIR/chroot" http://deb.debian.org/debian/

# ============================================================
# 4. Install packages and create user inside chroot
# ============================================================
echo "[*] Installing extra packages inside chroot..."

sudo chroot "$GEN_DIR/chroot" bash -c "
set -e
DEBIAN_FRONTEND=noninteractive apt update
DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
  systemd-sysv linux-image-amd64 live-boot sudo \
  thunar distrobox nsxiv xarchiver xorg xserver-xorg-core \
  xserver-xorg-video-all x11-xserver-utils x11-xkb-utils x11-utils \
  xinit xserver-xorg-input-libinput wmaker wmtime zenity

# Create user 'makaba' without password (password will be set at first GUI login)
useradd -m -s /bin/bash makaba
passwd -d makaba
adduser makaba sudo

# Create Applications folder
mkdir -p /home/makaba/Applications
chown -R makaba:makaba /home/makaba/Applications

# Create GUI password setup script in ~/.local/bin
mkdir -p /home/makaba/.local/bin
cat > /home/makaba/.local/bin/set-pass.sh <<'EOF'
#!/bin/bash
# Only run GUI password setup if a password is not yet set
if sudo getent shadow makaba | grep -qE '^[^:]+::|^[^:]+:!'; then
    # Ask for a new password using zenity dialog
    PASS=\$(zenity --password --title=\"Set password\" \
           --text=\"Create a password for user 'makaba'\")
    if [ -n \"\$PASS\" ]; then
        echo \"makaba:\$PASS\" | sudo chpasswd
        zenity --info --title=\"Password set\" \
               --text=\"Password for 'makaba' has been configured.\"
        # Optional: disable this script after the first run
        rm -f /home/makaba/.local/bin/set-pass.sh
    fi
fi
EOF

chmod +x /home/makaba/.local/bin/set-pass.sh
chown -R makaba:makaba /home/makaba/.local/bin

# Configure WindowMaker autostart to run the script
mkdir -p /home/makaba/GNUstep/Library/WindowMaker
cat > /home/makaba/GNUstep/Library/WindowMaker/autostart <<'EOF'
#!/bin/bash
[ -x /home/makaba/.local/bin/set-pass.sh ] && /home/makaba/.local/bin/set-pass.sh &
EOF

chmod +x /home/makaba/GNUstep/Library/WindowMaker/autostart
chown -R makaba:makaba /home/makaba/GNUstep

apt clean
"

# ============================================================
# 5. Prepare ISO filesystem with Zstandard compression
# ============================================================
echo "[*] Preparing ISO filesystem (Zstandard compression)..."
mkdir -p "$GEN_DIR/iso/live"
sudo mksquashfs "$GEN_DIR/chroot" "$GEN_DIR/iso/live/filesystem.squashfs" -e boot -comp zstd

# Copy kernel and initrd
sudo cp "$GEN_DIR/chroot/boot/vmlinuz"* "$GEN_DIR/iso/live/vmlinuz"
sudo cp "$GEN_DIR/chroot/boot/initrd.img"* "$GEN_DIR/iso/live/initrd"

# -------------------------
# UEFI boot (GRUB EFI)
# -------------------------
mkdir -p "$GEN_DIR/iso/EFI/BOOT" "$GEN_DIR/iso/boot/grub"

cat > "$GEN_DIR/iso/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

search --no-floppy --set=root --volid WMakerLive

menuentry "Live persistent system (amd64)" {
    linux /live/vmlinuz boot=live persistence quiet splash
    initrd /live/initrd
}

menuentry "Live system (amd64)" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd
}
EOF

grub-mkstandalone \
  --format=x86_64-efi \
  --output="$GEN_DIR/iso/EFI/BOOT/BOOTX64.EFI" \
  --locales="" \
  --themes="" \
  "boot/grub/grub.cfg=$GEN_DIR/iso/boot/grub/grub.cfg"

# Create EFI System Partition image inside ISO folder
dd if=/dev/zero of="$GEN_DIR/iso/EFI.img" bs=1M count=20
sudo mkfs.vfat "$GEN_DIR/iso/EFI.img"
mmd -i "$GEN_DIR/iso/EFI.img" ::/EFI ::/EFI/BOOT
mcopy -i "$GEN_DIR/iso/EFI.img" "$GEN_DIR/iso/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT

# ============================================================
# 6. Build UEFI-only ISO
# ============================================================
echo "[*] Creating UEFI-only ISO..."
xorriso -as mkisofs \
  -o "$OUTDIR/$ISONAME" \
  -V "WMakerLive" \
  -eltorito-alt-boot \
  -e EFI.img \
  -no-emul-boot -isohybrid-gpt-basdat \
  "$GEN_DIR/iso"

echo "[+] UEFI-only ISO created: $OUTDIR/$ISONAME"
