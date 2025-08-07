#!/usr/bin/env bash
set -euo pipefail

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Use sudo." >&2
  exit 1
fi

# Determine script directory and user
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="${SUDO_USER:-root}"
USER_HOME=$(eval echo "~$USER_NAME")
SOFTWARE_LIST="$SCRIPT_DIR/softwareList.txt"
WALLPAPERS_DIR="$USER_HOME/Wallpapers"

# 1. Update system
pacman -Syu --noconfirm

# 2. Enable SSD TRIM
echo "Enabling SSD TRIM..."
systemctl enable --now fstrim.timer

# 3. Reduce swappiness
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
sysctl --system

# 4. Enable a basic firewall with nftables
echo "Installing and configuring nftables..."
pacman -S --noconfirm nftables
cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif "lo" accept
        tcp dport ssh accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF
systemctl enable --now nftables

# Install NVIDIA driver and CUDA
echo "Installing NVIDIA driver and CUDA toolkit..."
pacman -S --noconfirm nvidia nvidia-utils cuda

# Set ZSH as the default shell
echo "Installing Zsh and setting it as default shell for $USER_NAME..."
pacman -S --noconfirm zsh
chsh -s /bin/zsh "$USER_NAME"

# Install paru (AUR helper)
echo "Installing paru (AUR helper)..."
pacman -S --noconfirm --needed base-devel git rust openssl
rm -rf /tmp/paru
sudo -u "$USER_NAME" git clone https://aur.archlinux.org/paru.git /tmp/paru
pushd /tmp/paru >/dev/null
sudo -u "$USER_NAME" makepkg --noconfirm --syncdeps --rmdeps
pkg_file=$(ls /tmp/paru/*.pkg.tar.* | head -n1)
pacman -U --noconfirm "$pkg_file"
popd >/dev/null
rm -rf /tmp/paru

# Allow passwordless pacman for $USER_NAME so paru can install without a TTY
echo "$USER_NAME ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/01-paru
chmod 440 /etc/sudoers.d/01-paru
export PARU_USE_SUDO=true

# Resolve iptables conflict and ensure nft variant is in place
echo "Removing legacy iptables packages..."
pacman -Rdd --noconfirm iptables || true
pacman -Rdd --noconfirm iptables-legacy || true

echo "Installing iptables-nft to satisfy firewall dependencies..."
pacman -S --noconfirm --needed iptables-nft

# Install programs from softwareList.txt as non-root user
echo "Installing packages listed in $SOFTWARE_LIST..."
if [[ -f "$SOFTWARE_LIST" ]]; then
  while IFS= read -r line; do
    # skip empty or comment lines
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    pkg_name="${line%% *}"
    echo "Building and installing $pkg_name..."
    runuser -l "$USER_NAME" -c "export PARU_USE_SUDO=true && paru -S --noconfirm --needed '$pkg_name' || echo \"Warning: failed to install $pkg_name, continuing...\" >&2"
  done < "$SOFTWARE_LIST"
else
  echo "Warning: $SOFTWARE_LIST not found. Skipping AUR installations." >&2
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
  runuser -l "$USER_NAME" -c "export PARU_USE_SUDO=true && paru -S --noconfirm --needed feh"
  runuser -l "$USER_NAME" -c "feh --bg-scale /usr/share/backgrounds/AntoineFlynnWallpaper.jpg"
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
BL_VERSION=$(blender --version 2>/dev/null | head -n1 | awk '{print $2}' || echo "")
if [[ -n "$BL_VERSION" ]]; then
  mkdir -p "$USER_HOME/.config/blender/$BL_VERSION"
  cp -r "$USER_HOME/.config/blender/blenderversion/"* "$USER_HOME/.config/blender/$BL_VERSION/" || true
  mkdir -p "/usr/share/blender/$BL_VERSION/scripts/startup/"
  cp -r "$USER_HOME/.config/blender/bl_app_templates_system" "/usr/share/blender/$BL_VERSION/scripts/startup/" || true
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

echo "Arch setup script complete!"
