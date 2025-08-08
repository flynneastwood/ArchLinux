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

# Install GTK theme and icon set (user-level, from scratch)
echo "Installing Skeuos theme and Tela icons to the user's home..."

# --- Configurable names ---
THEME_NAME="Skeuos-Blue-Dark"   # e.g., Skeuos-Blue-Light, Skeuos-Blue-Dark
ICON_NAME="Tela-dark"           # e.g., Tela, Tela-dark, etc.

# Users to apply theming to (include the invoking sudo user + extra accounts)
THEME_USERS=("$USER_NAME" "tony")

TMP_THEMES="$(mktemp -d)"
trap 'rm -rf "$TMP_THEMES"' EXIT
chmod 755 "$TMP_THEMES" # allow non-root user to traverse this temp dir

# Clone Skeuos once
rm -rf "$TMP_THEMES/skeuos"
git clone --depth 1 https://github.com/daniruiz/skeuos-gtk.git "$TMP_THEMES/skeuos"
SKEUOS_SRC=$(find "$TMP_THEMES/skeuos" -maxdepth 2 -type d -name "$THEME_NAME" | head -n1 || true)

# Iterate over target users and install per-user
for U in "${THEME_USERS[@]}"; do
  # Skip if user doesn't exist
  if ! id -u "$U" >/dev/null 2>&1; then
    echo "Warning: user $U not found; skipping theming for this user." >&2
    continue
  fi
  U_HOME=$(eval echo "~$U" 2>/dev/null || true)
  if [[ -z "$U_HOME" || ! -d "$U_HOME" ]]; then
    echo "Warning: home directory for $U not found; skipping." >&2
    continue
  fi

  # Ensure user theme/icon dirs exist with correct ownership
  sudo -u "$U" mkdir -p "$U_HOME/.themes" "$U_HOME/.icons"
  chown -R "$U:$U" "$U_HOME/.themes" "$U_HOME/.icons"

  # --- Install Skeuos GTK theme into user's ~/.themes ---
  if [[ -d "$SKEUOS_SRC" ]]; then
    rm -rf "$U_HOME/.themes/$THEME_NAME"
    cp -r "$SKEUOS_SRC" "$U_HOME/.themes/"
    chown -R "$U:$U" "$U_HOME/.themes/$THEME_NAME"
  else
    echo "Warning: Could not locate $THEME_NAME in Skeuos repo." >&2
  fi

  # --- Install Tela icons into user's ~/.icons via upstream installer ---
  # Ensure ~/.icons is a directory and remove any existing Tela icon dirs safely
  runuser -l "$U" -s /bin/bash -c '
    set -euo pipefail
    if [ -e "$HOME/.icons" ] && [ ! -d "$HOME/.icons" ]; then rm -f "$HOME/.icons"; fi
    mkdir -p "$HOME/.icons"
    find "$HOME/.icons" -maxdepth 1 -mindepth 1 -name "Tela*" -exec rm -rf {} +
  '

  # Clone & run Tela installer entirely as the target user so permissions are correct
  runuser -l "$U" -s /bin/bash -c '
    set -euo pipefail
    TMP_DIR=$(mktemp -d)
    git clone --depth 1 https://github.com/vinceliuice/Tela-icon-theme.git "$TMP_DIR/Tela-icon-theme"
    bash "$TMP_DIR/Tela-icon-theme/install.sh" -d "$HOME/.icons"
    rm -rf "$TMP_DIR"
  ' || echo "Warning: Tela installer failed for $U — continuing..." >&2

  # Apply theme and icon settings (XFCE offline) for this user
  # Ensure ~/.config exists and is owned by the user
  install -d -m 700 -o "$U" -g "$U" "$U_HOME/.config"
  CFG="$U_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
  # Use Tela-dark; if it doesn't exist, fall back to Tela
  ICON_FOR_USER="$ICON_NAME"
  if [[ ! -d "$U_HOME/.icons/$ICON_FOR_USER" && ! -d "/usr/share/icons/$ICON_FOR_USER" ]]; then
    if [[ -d "$U_HOME/.icons/Tela" || -d "/usr/share/icons/Tela" ]]; then
      ICON_FOR_USER="Tela"
    fi
  fi
  install -d -o "$U" -g "$U" "$(dirname "$CFG")"
  cat > "$CFG" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="$THEME_NAME"/>
    <property name="IconThemeName" type="string" value="$ICON_FOR_USER"/>
  </property>
</channel>
EOF
  chown -R "$U:$U" "$U_HOME/.config/xfce4"

  # GTK fallback settings for stubborn sessions (affects many apps directly)
  install -d -m 700 -o "$U" -g "$U" "$U_HOME/.config/gtk-3.0"
  cat > "$U_HOME/.config/gtk-3.0/settings.ini" <<EOF
[Settings]
gtk-theme-name=$THEME_NAME
gtk-icon-theme-name=$ICON_FOR_USER
EOF
  chown -R "$U:$U" "$U_HOME/.config/gtk-3.0"

  # GTK2 fallback (some XFCE bits/plugins still read this)
  echo -e "gtk-theme-name=\"$THEME_NAME\"
gtk-icon-theme-name=\"$ICON_FOR_USER\"" > "$U_HOME/.gtkrc-2.0"
  chown "$U:$U" "$U_HOME/.gtkrc-2.0"


  echo "Applied $THEME_NAME + $ICON_FOR_USER for user $U"
done

# Set default applications per user (avoid writing to /root)
echo "Setting default applications per user..."
for U in "${THEME_USERS[@]}"; do
  if ! id -u "$U" >/dev/null 2>&1; then continue; fi

  # Choose available .desktop files safely
  IMG=""; for d in nsxiv.desktop sxiv.desktop imv.desktop ristretto.desktop eog.desktop org.gnome.eog.desktop; do [[ -f "/usr/share/applications/$d" ]] && IMG="$d" && break; done
  VID=""; for d in mpv.desktop vlc.desktop parole.desktop; do [[ -f "/usr/share/applications/$d" ]] && VID="$d" && break; done
  PDF=""; for d in firefox.desktop org.pwmt.zathura.desktop org.gnome.Evince.desktop evince.desktop; do [[ -f "/usr/share/applications/$d" ]] && PDF="$d" && break; done

  runuser -l "$U" -s /bin/bash -c "\
    mkdir -p \"$HOME/.config\"; \
    ${IMG:+xdg-mime default $IMG image/png image/jpeg image/bmp || true}; \
    ${VID:+xdg-mime default $VID video/mp4 video/x-matroska || true}; \
    ${PDF:+xdg-mime default $PDF application/pdf || true} \
  "
done

echo "Arch setup script complete!"
