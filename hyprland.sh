#!/bin/sh
set -eu

# ---------------- Configuration (override via env) ----------------
: "${USERNAME:=archuser}"      # must exist (created by setup.sh)
: "${RUN_GPU_AUTO:=1}"         # 1=auto-detect GPU drivers
: "${DEFAULT_SHELL:=/bin/bash}"
# -----------------------------------------------------------------

msg() { printf '\n==> %s\n' "$*"; }

# Resolve target user
if ! id -u "$USERNAME" >/dev/null 2>&1; then
  CANDIDATE="$(awk -F: '$3>=1000 && $1!="nobody"{print $1; exit}' /etc/passwd || true)"
  [ -n "$CANDIDATE" ] || { echo "ERROR: No regular user found. Set USERNAME=..."; exit 1; }
  USERNAME="$CANDIDATE"
fi
USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"

# -----------------------------------------------------------------
# Core Wayland + Hyprland stack (no greetd anywhere)
# -----------------------------------------------------------------
msg "Installing Wayland + Hyprland + desktop essentials"
pacman -Sy --noconfirm --needed \
  hyprland hyprpaper hypridle hyprlock \
  xorg-xwayland \
  xdg-desktop-portal xdg-desktop-portal-hyprland xdg-user-dirs \
  polkit polkit-gnome \
  wl-clipboard grim slurp \
  waybar wofi \
  kitty \
  thunar tumbler ffmpegthumbnailer gvfs gvfs-smb \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  network-manager-applet \
  bluez bluez-utils blueman \
  brightnessctl playerctl pavucontrol \
  noto-fonts noto-fonts-emoji ttf-dejavu \
  sddm qt6-wayland

# -----------------------------------------------------------------
# GPU drivers (simple auto-detect)
# -----------------------------------------------------------------
if [ "$RUN_GPU_AUTO" = "1" ]; then
  msg "Auto-detecting GPU and installing drivers"
  GPU_LINE="$(lspci -nnk | grep -E 'VGA|3D|Display' | head -n1 || true)"
  case "$GPU_LINE" in
    *NVIDIA*|*nVidia*|*GeForce*)
      pacman -Sy --noconfirm --needed nvidia nvidia-utils nvidia-settings
      # Enable DRM KMS for smoother Wayland on NVIDIA
      if [ -f /etc/default/grub ]; then
        sed -i 's/^GRUB_CMDLINE_LINUX="\([^"]*\)"/GRUB_CMDLINE_LINUX="\1 nvidia_drm.modeset=1"/' /etc/default/grub || true
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null || true
      fi
      ;;
    *AMD*|*Advanced\ Micro\ Devices*|*Radeon*)
      pacman -Sy --noconfirm --needed mesa vulkan-radeon libva-mesa-driver ;;
    *Intel*|*UHD*|*Iris*)
      pacman -Sy --noconfirm --needed mesa vulkan-intel intel-media-driver ;;
    *)
      echo "NOTE: Unknown GPU; installing mesa fallback"
      pacman -Sy --noconfirm --needed mesa ;;
  esac
fi

# -----------------------------------------------------------------
# Configure & enable SDDM (Wayland)
# -----------------------------------------------------------------
msg "Configuring SDDM (Wayland greeter)"
install -d -m 755 /etc/sddm.conf.d
cat >/etc/sddm.conf.d/10-wayland.conf <<'EOF'
[General]
DisplayServer=wayland

[Wayland]
EnableHiDPI=true
SessionDir=/usr/share/wayland-sessions

[X11]
EnableHiDPI=true
EOF

# Ensure Hyprland session is present (hyprland package normally provides it)
if [ ! -f /usr/share/wayland-sessions/hyprland.desktop ]; then
  cat >/usr/share/wayland-sessions/hyprland.desktop <<'EOF'
[Desktop Entry]
Name=Hyprland
Comment=Hyprland Wayland compositor
Exec=Hyprland
Type=Application
DesktopNames=Hyprland
EOF
fi

systemctl enable sddm

# -----------------------------------------------------------------
# Minimal Hyprland user config (polished defaults; updated shadow{} syntax)
# -----------------------------------------------------------------
msg "Writing user configs for $USERNAME"
install -d -m 755 "$USER_HOME/.config/hypr" "$USER_HOME/.config/waybar" "$USER_HOME/.config/wofi"

cat >"$USER_HOME/.config/hypr/hyprland.conf" <<'EOF'
# Minimal Hyprland config
monitor=,preferred,auto,1

input {
  kb_layout = us
  follow_mouse = 1
  touchpad { natural_scroll = true }
}

general {
  gaps_in = 5
  gaps_out = 10
  border_size = 2
  col.active_border = rgba(89b4faee)
  col.inactive_border = rgba(6c708699)
}

decoration {
  rounding = 12
  blur { enabled = yes; size = 8; passes = 2; vibrancy = 0.15 }
  shadow { enabled = yes; range = 25; render_power = 3; color = rgba(00000099) }
}

animations {
  enabled = yes
  bezier = smooth, 0.05, 0.9, 0.1, 1.0
  animation = windows, 1, 7, smooth, popin 60%
  animation = windowsOut, 1, 7, smooth, popin 60%
  animation = workspaces, 1, 6, smooth, slide
  animation = layers, 1, 6, smooth, popin 70%
  animation = border, 1, 10, smooth
}

# Autostart on login
exec-once = dbus-update-activation-environment --systemd --all
exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = xdg-user-dirs-update
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = hyprpaper
exec-once = waybar
exec-once = nm-applet --indicator
exec-once = blueman-applet

# Keybinds
bind = SUPER, Return, exec, kitty
bind = SUPER, Q, killactive
bind = SUPER, F, fullscreen
bind = SUPER, D, exec, wofi --show drun
bind = SUPER CTRL, L, exec, hyprlock
bind = SUPER, E, exec, thunar

bind = SUPER, H, movefocus, l
bind = SUPER, J, movefocus, d
bind = SUPER, K, movefocus, u
bind = SUPER, L, movefocus, r

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

# Ownership & (optional) default shell
chown -R "$USERNAME":"$USERNAME" "$USER_HOME/.config"
if [ -x "$DEFAULT_SHELL" ]; then
  CUR_SHELL="$(getent passwd "$USERNAME" | cut -d: -f7 || echo /bin/bash)"
  [ "$CUR_SHELL" = "$DEFAULT_SHELL" ] || chsh -s "$DEFAULT_SHELL" "$USERNAME" || true
fi

msg "SDDM is installed and enabled. Reboot to the SDDM login screen and select 'Hyprland'."
