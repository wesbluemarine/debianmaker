#!/bin/bash
set -e

# ==========================================================
# 1) Cleanup and setup working directory
# ==========================================================
rm -rf live-build-workdir
mkdir -p live-build-workdir
cd live-build-workdir

# ==========================================================
# 2) Configure live-build
# ==========================================================
lb config \
  --distribution trixie \
  --architecture amd64 \
  --archive-areas "main contrib non-free non-free-firmware" \
  --binary-images iso-hybrid \
  --bootappend-live "persistence toram" \
  --debian-installer live \
  --iso-volume "debian-trixie-xfce" \
  --iso-publisher "Custom Debian Live" \
  --mirror-bootstrap http://deb.debian.org/debian/ \
  --mirror-binary http://deb.debian.org/debian/ \
  --apt-indices false \
  --apt-source false \
  --compress xz

# ==========================================================
# 3) Base packages
# ==========================================================
cat > config/package-lists/custom.list.chroot <<EOF
task-xfce-desktop
lightdm
lightdm-gtk-greeter
xfce4-terminal
xfce4-appmenu-plugin
xfce4-indicator-plugin
flatpak
EOF

# Explicitly remove xterm
cat > config/package-lists/remove.list.chroot <<EOF
xterm-
EOF

# ==========================================================
# 4) Hook: fix sources.list inside chroot
# ==========================================================
mkdir -p config/hooks/live-bottom
cat > config/hooks/live-bottom/030-fix-sources.chroot <<'HOOK'
#!/bin/sh
set -e
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
HOOK
chmod +x config/hooks/live-bottom/030-fix-sources.chroot

# ==========================================================
# 5) Hook: XFCE default panel configuration
# ==========================================================
mkdir -p config/hooks/live-bottom
cat > config/hooks/live-bottom/040-fix-xfce.chroot <<'HOOK'
#!/bin/sh
set -e

USER_HOME="/home/user"
mkdir -p "$USER_HOME/.config/xfce4/xfconf/xfce-perchannel-xml"

cat > "$USER_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
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
    <property name="plugin-1" type="string" value="applicationsmenu">
      <property name="show-icon" type="bool" value="false"/>
      <property name="button-title" type="string" value="Applications"/>
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
      <property name="digital-format" type="string" value="%A, %d %B %Y %I:%M %p"/>
    </property>
  </property>
</channel>
EOF

chown -R user:user "$USER_HOME/.config"
HOOK
chmod +x config/hooks/live-bottom/040-fix-xfce.chroot

# ==========================================================
# 6) Hook: set environment variables for AppMenu
# ==========================================================
cat > config/hooks/live-bottom/020-environment.chroot <<'HOOK'
#!/bin/sh
set -e
cat > /etc/environment <<EOF
UBUNTU_MENUPROXY=1
GTK_MODULES=appmenu-gtk-module
EOF
HOOK
chmod +x config/hooks/live-bottom/020-environment.chroot

# ==========================================================
# 7) Hook: LightDM autologin with default user
# ==========================================================
cat > config/hooks/live-bottom/050-lightdm-autologin.chroot <<'HOOK'
#!/bin/sh
set -e
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/60-autologin.conf <<EOF
[Seat:*]
autologin-user=user
autologin-user-timeout=0
EOF

# Create default user
useradd -m -s /bin/bash user || true
echo "user:live" | chpasswd
usermod -aG sudo user
HOOK
chmod +x config/hooks/live-bottom/050-lightdm-autologin.chroot

# ==========================================================
# 8) Build ISO
# ==========================================================
lb build
