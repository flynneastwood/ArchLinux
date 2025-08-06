#!/usr/bin/env bash
set -euo pipefail

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Use sudo." >&2
  exit 1
fi

# The user invoking sudo
USER_NAME="$SUDO_USER"
USER_HOME=$(eval echo "~$USER_NAME")
SOFTWARE_LIST="softwareList.txt"
WALLPAPERS_DIR="$USER_HOME/Wallpapers"

# 1. Update system
pacman -Syu --noconfirm

# 2. Enable SSD TRIM
echo "Enabling SSD TRIM..."
systemctl enable --now fstrim.timer

# 3. Reduce swappiness
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
sysctl --system

# 4. Enable a basic firewall (ufw)
echo "Installing and configuring UFW..."
pacman -S --noconfirm ufw
systemctl enable --now ufw
ufw default deny incoming
ufw default allow outgoing
echo "y" | ufw enable

# Install NVIDIA driver and CUDA
echo "Installing NVIDIA driver and CUDA toolkit..."
pacman -S --noconfirm nvidia nvidia-utils cuda

# Set ZSH as the default shell
echo "Installing Zsh and setting it as default shell for $USER_NAME..."
pacman -S --noconfirm zsh
chsh -s /bin/zsh "$USER_NAME"

# Install paru (AUR helper)
echo "Installing paru (AUR helper)..."
pacman -S --noconfirm --needed base-devel git
rm -rf /tmp/paru
echo "Cloning paru repository as $USER_NAME..."
sudo -u "$USER_NAME" git clone https://aur.archlinux.org/paru.git /tmp/paru
echo "Building and installing paru..."
pushd /tmp/paru >/dev/null
sudo -u "$USER_NAME" makepkg -si --noconfirm
popd >/dev/null
rm -rf /tmp/paru

# Install programs from softwareList.txt
if [[ -f "$SOFTWARE_LIST" ]]; then
  echo "Installing packages from $SOFTWARE_LIST..."
  # Ensure gmic for Krita
  paru -S --noconfirm gmic
  xargs -a "$SOFTWARE_LIST" -r paru -S --noconfirm
else
  echo "Warning: $SOFTWARE_LIST not found in $(pwd)." >&2
fi

# Install GTK theme and icon set
echo "Installing Skeuos-Blue-Dark theme and Tela icons..."
git clone https://github.com/daniruiz/skeuos-gtk.git /usr/share/themes/Skeuos-Blue-Dark
git clone https://github.com/vinceliuice/Tela-icon-theme.git /usr/share/icons/Tela
gtk-update-icon-cache -f /usr/share/icons/Tela

# Install wallpapers and set default
echo "Copying wallpapers to /usr/share/backgrounds and setting default..."
mkdir -p /usr/share/backgrounds
if [[ -d "$WALLPAPERS_DIR" ]]; then
  cp -r "$WALLPAPERS_DIR/"* /usr/share/backgrounds/
  # Install feh if not present
  paru -S --noconfirm feh
  feh --bg-scale /usr/share/backgrounds/AntoineFlynnWallpaper.jpg
else
  echo "Warning: Wallpapers directory $WALLPAPERS_DIR does not exist." >&2
fi

# Install fonts
echo "Copying fonts to /usr/share/fonts..."
if [[ -d "$USER_HOME/.fonts" ]]; then
  mkdir -p /usr/share/fonts
  cp -r "$USER_HOME/.fonts/"* /usr/share/fonts/
  fc-cache -f
else
  echo "Warning: Font directory $USER_HOME/.fonts not found." >&2
fi

# Configure Blender user settings
echo "Configuring Blender environment..."
# Determine installed Blender version
BL_VERSION=$(blender --version 2>/dev/null | head -n1 | awk '{print $2}' || echo "")
if [[ -n "$BL_VERSION" ]]; then
  # Copy user templates
  mkdir -p "$USER_HOME/.config/blender/$BL_VERSION"
  cp -r "$USER_HOME/.config/blender/blenderversion/"* "$USER_HOME/.config/blender/$BL_VERSION/" || true

  # Copy system app templates
  mkdir -p "/usr/share/blender/$BL_VERSION/scripts/startup/"
  cp -r "$USER_HOME/.config/blender/bl_app_templates_system" "/usr/share/blender/$BL_VERSION/scripts/startup/" || true

  # Install Dark Wood theme preset
  PRESET_DIR="/usr/share/blender/$BL_VERSION/scripts/presets/interface_theme"
  mkdir -p "$PRESET_DIR"
  cp "$USER_HOME/.config/blender/Dark_Wood.xml" "$PRESET_DIR/"
else
  echo "Blender not found or version detection failed." >&2
fi

# Set default applications
echo "Setting default applications..."
xdg-mime default sxiv.desktop image/png image/jpeg image/bmp
xdg-mime default mpv.desktop video/mp4 video/x-matroska
xdg-mime default firefox.desktop application/pdf

# Done
echo "Arch setup script complete!"
