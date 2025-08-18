#!/bin/sh
set -eu

# ---------------- Configuration (override via env when calling) ---------------
: "${USERNAME:=archuser}"      # created by setup.sh
: "${RUN_GPU_AUTO:=1}"         # 1=auto-detect GPU drivers
: "${DEFAULT_SHELL:=/bin/bash}"
# -----------------------------------------------------------------------------

msg() { printf '\n==> %s\n' "$*"; }

# Find a non-root user if USERNAME is missing/wrong
if ! id -u "$USERNAME" >/dev/null 2>&1; then
  # try the first UID >= 1000
  CANDIDATE="$(awk -F: '$3>=1000 && $1!="nobody"{print $1; exit}' /etc/passwd || true)"
  if [ -n "$CANDIDATE" ]; then
    USERNAME="$CANDIDATE"
  else
    echo "ERROR: No suitable non-root user found. Set USERNAME=... and rerun."
    exit 1
  fi
fi

msg "Installing base GUI / Wayland stack (Hyprland + essentials)"
# Base Wayland + Hyprland ecosystem
pacman -Sy --noconfirm --needed \
  hyprland hyprpaper hypridle hyprlock \
  xorg-xwayland \
  xdg-desktop-portal xdg-desktop-portal-hyprland xdg-user-dirs \
  polkit \
  wl-clipboard grim slurp \
  waybar \
  wofi \
  kitty \
  thunar tumbler ffmpegthumbnailer gvfs gvfs-smb \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  network-manager-applet \
  bluez bluez-utils blueman \
  brightnessctl playerctl pavucontrol \
  noto-fonts noto-fonts-emoji ttf-dejavu

# Login manager: greetd + tui greeter (works great on bare Wayland)
pacman -Sy --noconfirm --needed greetd tuigreet

# Optional Qt Wayland bits
pacman -Sy --noconfirm --needed qt5-wayland qt6-wayland

# GPU drivers (auto-detect)
if [ "$RUN_GPU_AUTO" = "1" ]; then
  msg "Auto-detecting GPU and installing drivers"
  GPU_LINE="$(lspci -nnk | grep -E 'VGA|3D|Display' | head -n1 || true)"
  case "$GPU_LINE" in
    *NVIDIA*|*nVidia*|*GeForce*)
      pacman -Sy --noconfirm --needed nvidia nvidia-utils nvidia-settings
      # Enable DRM KMS for Wayland
      if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub 2>/dev/null; then
        sed -i 's/^GRUB_CMDLINE_LINUX="\([^"]*\)"/GRUB_CMDLINE_LINUX="\1 nvidia_drm.modeset=1"/' /etc/default/grub
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null
      fi
      ;;
    *AMD*|*Advanced\ Micro\ Devices*|*Radeon*)
      pacman -Sy --noconfirm --needed mesa vulkan-radeon libva-mesa-driver
      ;;
    *Intel*|*UHD*|*Iris*)
      pacman -Sy --noconfirm --needed mesa vulkan-intel intel-media-driver
      ;;
    *)
      echo "NOTE: Unknown GPU in: $GPU_LINE"
      pacman -Sy --noconfirm --needed mesa  # generic fallback
      ;;
  esac
fi

# Enable runtime services
msg "Enabling services (greetd, Bluetooth, NM, audio/timesync already handled)"
systemctl enable greetd
systemctl enable bluetooth.service
# NetworkManager + sshd likely enabled in setup.sh; if not, uncomment:
# systemctl enable NetworkManager
# systemctl enable sshd

# Configure greetd (tuigreet -> launch Hyprland)
msg "Configuring greetd with tuigreet"
install -d -m 755 /etc/greetd
cat >/etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --remember --asterisks --time --cmd Hyprland"
user = "greeter"
EOF

# Ensure pam config exists for greetd (comes with package, but just in case)
if [ ! -f /etc/pam.d/greetd ]; then
  cat >/etc/pam.d/greetd <<'EOF'
#%PAM-1.0
auth        include     system-login
account     include     system-login
password    include     system-login
session     include     system-login
EOF
fi

# User config: Hyprland + Waybar + Wofi + Hyprpaper basics
msg "Writing user configs for $USERNAME"
USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
[ -n "$USER_HOME" ] || { echo "ERROR: cannot find home for $USERNAME"; exit 1; }

# Hyprland config
install -d -m 755 "$USER_HOME/.config/hypr"
cat >"$USER_HOME/.config/hypr/hyprland.conf" <<'EOF'
# Minimal Hyprland config
monitor=,preferred,auto,1

# Inputs
input {
  kb_layout = us
  follow_mouse = 1
  touchpad {
    natural_scroll = true
  }
}

# Aesthetics
general {
  gaps_in = 5
  gaps_out = 10
  border_size = 2
  col.active_border = rgba(89b4faee)
  col.inactive_border = rgba(6c708699)
}

# Autostart on login
exec-once = dbus-update-activation-environment --systemd --all
exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = xdg-user-dirs-update
exec-once = hyprpaper
exec-once = waybar
exec-once = nm-applet --indicator
exec-once = blueman-applet

# Wallpaper (set a default solid color; user can edit hyprpaper.conf to use an image)
exec-once = sh -c 'printf "preload = /usr/share/backgrounds/archlinux/archbtw.jpg\nwallpaper = ,/usr/share/backgrounds/archlinux/archbtw.jpg\n" > $HOME/.config/hypr/hyprpaper.conf; [ -f /usr/share/backgrounds/archlinux/archbtw.jpg ] || convert -size 3840x2160 xc:#1e1e2e /usr/share/backgrounds/archlinux/archbtw.jpg 2>/dev/null || true'

# Simple keybinds
bind = SUPER, Return, exec, kitty
bind = SUPER, Q, killactive
bind = SUPER, F, fullscreen
bind = SUPER, D, exec, wofi --show drun
bind = SUPER, C, exec, hyprlock
bind = SUPER CTRL, L, exec, hyprlock
bind = SUPER, E, exec, thunar

# Move focus
bind = SUPER, H, movefocus, l
bind = SUPER, J, movefocus, d
bind = SUPER, K, movefocus, u
bind = SUPER, L, movefocus, r

# Workspace
bind = SUPER, 1, workspace, 1
bind = SUPER, 2, workspace, 2
bind = SUPER, 3, workspace, 3
bind = SUPER, 4, workspace, 4
bind = SUPER, 5, workspace, 5
bind = SUPER, 6, workspace, 6
bind = SUPER, 7, workspace, 7
bind = SUPER, 8, workspace, 8
bind = SUPER, 9, workspace, 9
bind = SUPER, 0, workspace, 10
EOF

# Waybar (minimal—Waybar ships defaults; create dir to avoid warnings)
install -d -m 755 "$USER_HOME/.config/waybar"

# Wofi (optional config dir)
install -d -m 755 "$USER_HOME/.config/wofi"

# Ensure user owns the files
chown -R "$USERNAME":"$USERNAME" "$USER_HOME/.config"

# User lingering (so user units can run after login if needed)
loginctl enable-linger "$USERNAME" 2>/dev/null || true

# Default shell (matches setup.sh user)
if [ -x "$DEFAULT_SHELL" ]; then
  chsh -s "$DEFAULT_SHELL" "$USERNAME" || true
fi

# Polkit rules example (optional, not adding permissive rules by default)

msg "Hyprland setup complete."
echo "You can now reboot. On next boot, greetd/tuigreet will let you log in and start Hyprland."
