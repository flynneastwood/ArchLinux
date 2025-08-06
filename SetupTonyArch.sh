#!/usr/bin/env bash
# setup-arch.sh — automate Arch Linux post-install configuration
# Run as root on a vanilla Arch install.

set -euo pipefail
IFS=$'\n\t'

# Ensure we're root
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

SCRIPT_DIR="$(pwd)"

echo "==> 1. Update mirror list and system"
pacman -S --noconfirm --needed reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syyu --noconfirm

echo "==> 2. Enable SSD TRIM"
systemctl enable --now fstrim.timer

echo "==> 3. Reduce swappiness"
cat > /etc/sysctl.d/99-swappiness.conf <<EOF
# lower swappiness for SSD
vm.swappiness=10
EOF

echo "==> 4. Enable a basic firewall (ufw)"
pacman -S --noconfirm --needed ufw
systemctl enable --now ufw
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

echo "==> Install Zsh and make it the default shell"
pacman -S --noconfirm --needed zsh
# Change root shell; new users get ZSH via skeleton (below)
chsh -s /usr/bin/zsh

echo "==> Install AUR helper 'paru'"
pacman -S --noconfirm --needed base-devel git
cd /tmp
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si --noconfirm
cd /
rm -rf /tmp/paru

echo "==> Installing packages from softwareList.txt"
if [[ -f "${SCRIPT_DIR}/softwareList.txt" ]]; then
  # ensure gmic before krita
  grep -xq "krita" "${SCRIPT_DIR}/softwareList.txt" \
    && sed -i '/krita/i gmic' "${SCRIPT_DIR}/softwareList.txt" || true
  paru -S --noconfirm --needed - < "${SCRIPT_DIR}/softwareList.txt"
else
  echo "WARNING: softwareList.txt not found in ${SCRIPT_DIR}"
fi

echo "==> Installing Skeuos-Blue-Dark theme and Tela icons"
# themes
mkdir -p /usr/share/themes
git clone https://github.com/daniruiz/skeuos-gtk.git /tmp/skeuos-gtk
cp -r /tmp/skeuos-gtk/Skeuos-Blue-Dark /usr/share/themes/
rm -rf /tmp/skeuos-gtk
# icons
mkdir -p /usr/share/icons
git clone https://github.com/vinceliuice/Tela-icon-theme.git /tmp/Tela-icon-theme
cp -r /tmp/Tela-icon-theme/Tela /usr/share/icons/
rm -rf /tmp/Tela-icon-theme

echo "==> Copying system-wide wallpapers"
mkdir -p /usr/share/backgrounds
if [[ -d "${SCRIPT_DIR}/Wallpapers" ]]; then
  cp -r "${SCRIPT_DIR}/Wallpapers/"* /usr/share/backgrounds/
  # set default for new users via feh in skeleton
  echo 'feh --bg-scale /usr/share/backgrounds/AntoineFlynnWallpaper.jpg' \
    > /etc/skel/.fehbg
else
  echo "WARNING: Wallpapers folder not found in ${SCRIPT_DIR}"
fi

echo "==> Installing user fonts system-wide"
mkdir -p /usr/local/share/fonts
if [[ -d "${SCRIPT_DIR}/.fonts" ]]; then
  cp -r "${SCRIPT_DIR}/.fonts/"* /usr/local/share/fonts/
  fc-cache -fv
else
  echo "WARNING: .fonts folder not found in ${SCRIPT_DIR}"
fi

echo "==> Configuring Blender"
# detect installed blender version
BL_VER=$(blender --version | head -n1 | awk '{print $2}')
USER_BL_DIR="/root/.config/blender/$BL_VER"
mkdir -p "$USER_BL_DIR"

# copy user templates
if [[ -d "${SCRIPT_DIR}/.config/blender/blenderversion" ]]; then
  cp -r "${SCRIPT_DIR}/.config/blender/blenderversion/"* "$USER_BL_DIR/"
else
  echo "WARNING: blender blenderversion folder missing"
fi

# system templates
SYS_BL_DIR="/usr/share/blender/$BL_VER/scripts/startup"
mkdir -p "$SYS_BL_DIR"
if [[ -d "${SCRIPT_DIR}/.config/blender/bl_app_templates_system" ]]; then
  cp -r "${SCRIPT_DIR}/.config/blender/bl_app_templates_system/"* "$SYS_BL_DIR/"
else
  echo "WARNING: bl_app_templates_system folder missing"
fi

# copy and install Dark_Wood.xml theme
if [[ -f "${SCRIPT_DIR}/.config/blender/Dark_Wood.xml" ]]; then
  BL_CONF_DIR="$USER_BL_DIR/config"
  mkdir -p "$BL_CONF_DIR/themes"
  cp "${SCRIPT_DIR}/.config/blender/Dark_Wood.xml" "$BL_CONF_DIR/themes/"
  # auto-apply theme on first run
  cat >> /etc/skel/.bash_profile <<'EOF'
# set Blender default theme
blender --background --python-expr "
import bpy, os
xp = os.path.expanduser('~/.config/blender/{ver}/config/themes/Dark_Wood.xml'.format(ver='{ver}'))
bpy.ops.preferences.themes_install(overwrite=True, ignore_version=True, filepath=xp)
bpy.ops.wm.save_userpref()
"
EOF
else
  echo "WARNING: Dark_Wood.xml not found"
fi

echo "==> Setting default apps (image -> sxiv, video -> mpv, PDF -> Firefox)"
# images
for m in image/jpeg image/png image/gif image/webp; do
  xdg-mime default sxiv.desktop "$m"
done
# video
for m in video/mp4 video/webm video/x-matroska; do
  xdg-mime default mpv.desktop "$m"
done
# PDF
xdg-mime default firefox.desktop application/pdf

echo "==> Done! Reboot when ready."
