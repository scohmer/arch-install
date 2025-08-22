#!/usr/bin/env bash
set -euo pipefail

# =========================
#  Arch + SDDM + ml4w Hyprland
#  Single-run installer
# =========================

# ---------- CONFIG: tweak to your liking ----------
USERNAME="${USERNAME:-dev}"            # target user to (create and) configure
HOSTNAME="${HOSTNAME:-archbox}"        # machine hostname
TIMEZONE="${TIMEZONE:-America/New_York}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"

# If you keep your ml4w dotfiles somewhere specific, put it here:
# Example: https://github.com/mylinuxforwork/ml4w-hyprland
ML4W_DOTFILES_REPO="${ML4W_DOTFILES_REPO:-}"
ML4W_DOTFILES_BRANCH="${ML4W_DOTFILES_BRANCH:-main}"

# Skip user creation if the user already exists
CREATE_USER_IF_MISSING="${CREATE_USER_IF_MISSING:-1}"

# Install a reasonable Hyprland desktop stack
EXTRA_DESKTOP_PKGS="kitty waybar wofi rofi-wayland grim slurp swappy \
xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-hyprland \
pipewire pipewire-alsa pipewire-pulse wireplumber polkit-gnome \
xdg-user-dirs wl-clipboard brightnessctl pavucontrol network-manager-applet \
ttf-dejavu ttf-liberation noto-fonts"

# ---------- Helpers ----------
log()  { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
die()  { printf "\n\033[1;31m[x] %s\033[0m\n" "$*"; exit 1; }

need_root() { [[ "$(id -u)" -eq 0 ]] || die "Run as root."; }

exists() { command -v "$1" &>/dev/null; }

enable_service() {
  local svc="$1"
  if systemctl is-enabled --quiet "$svc"; then
    log "Service already enabled: $svc"
  else
    systemctl enable "$svc"
    log "Enabled: $svc"
  fi
  if systemctl is-active --quiet "$svc"; then
    log "Service already running: $svc"
  else
    systemctl start "$svc"
    log "Started: $svc"
  fi
}

disable_if_present() {
  local svc="$1"
  if systemctl list-unit-files | grep -q "^${svc}.service"; then
    if systemctl is-active --quiet "$svc"; then
      systemctl stop "$svc" || true
    fi
    if systemctl is-enabled --quiet "$svc"; then
      systemctl disable "$svc" || true
    fi
    log "Disabled: $svc"
  fi
}

user_exists() {
  id -u "$1" &>/dev/null
}

# ---------- Pre-flight ----------
need_root

if ! ping -c1 -W2 archlinux.org &>/dev/null; then
  warn "No ping to archlinux.org; ensure networking is up for package installs."
fi

log "Refreshing package databases"
pacman -Sy --noconfirm

# ---------- Base system config (safe to run in chroot or installed system) ----------
log "Setting hostname, timezone, keymap, and locale"
echo "$HOSTNAME" > /etc/hostname

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

# Ensure locale is present in /etc/locale.gen
if ! grep -q "^${LOCALE} UTF-8" /etc/locale.gen; then
  sed -i "s/^#\(${LOCALE} UTF-8\)/\1/" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
fi
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# ---------- Networking ----------
log "Installing & enabling NetworkManager"
pacman -S --noconfirm --needed networkmanager
enable_service NetworkManager

# ---------- User setup ----------
if [[ "$CREATE_USER_IF_MISSING" -eq 1 ]]; then
  if user_exists "$USERNAME"; then
    log "User exists: $USERNAME"
  else
    log "Creating user: $USERNAME"
    useradd -m -G wheel,video,audio,input "$USERNAME"
    passwd "$USERNAME"
  fi
fi

if ! grep -qE '^%wheel ALL=\(ALL:ALL\) NOPASSWD: ALL' /etc/sudoers; then
  log "Configuring sudo for wheel (NOPASSWD)"
  sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
  echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers
fi

# ---------- Display Manager: switch to SDDM ----------
log "Installing SDDM"
pacman -S --noconfirm --needed sddm

log "Disabling other display managers if present"
for dm in gdm lightdm lxdm ly greetd; do
  disable_if_present "$dm"
done

log "Enabling SDDM"
enable_service sddm

# ---------- Hyprland + Wayland desktop stack ----------
log "Installing Hyprland and desktop packages"
pacman -S --noconfirm --needed hyprland ${EXTRA_DESKTOP_PKGS}

# ---------- SDDM Session for ml4w-Hyprland ----------
ML4W_SESSION_FILE="/usr/share/wayland-sessions/ml4w-hyprland.desktop"
if [[ ! -f "$ML4W_SESSION_FILE" ]]; then
  log "Creating ml4w-Hyprland SDDM session"
  cat > "$ML4W_SESSION_FILE" <<'EOF'
[Desktop Entry]
Name=ml4w-Hyprland
Comment=Hyprland session with ml4w config
Exec=/usr/bin/Hyprland
Type=Application
DesktopNames=ml4w-hyprland;Hyprland
EOF
else
  log "ml4w-Hyprland session already exists"
fi

# ---------- Dotfiles (optional but recommended) ----------
if [[ -n "$ML4W_DOTFILES_REPO" ]]; then
  if ! user_exists "$USERNAME"; then
    warn "User $USERNAME does not exist; skipping dotfiles clone."
  else
    log "Cloning ml4w dotfiles for $USERNAME"
    sudo -u "$USERNAME" bash -c "
      set -euo pipefail
      umask 022
      mkdir -p \"\$HOME/.config\"
      if [[ ! -d \"\$HOME/.local/share\" ]]; then mkdir -p \"\$HOME/.local/share\"; fi
      if [[ ! -d \"\$HOME/.ml4w-dots\" ]]; then
        git clone --depth 1 -b \"$ML4W_DOTFILES_BRANCH\" \"$ML4W_DOTFILES_REPO\" \"\$HOME/.ml4w-dots\"
      else
        cd \"\$HOME/.ml4w-dots\" && git fetch && git checkout \"$ML4W_DOTFILES_BRANCH\" && git pull
      fi

      # Example: sync configs (adjust to match your repo layout)
      # rsync -a --delete \"\$HOME/.ml4w-dots/config/\" \"\$HOME/.config/\"
    "
  fi
else
  warn "ML4W_DOTFILES_REPO not set. Skipping dotfiles."
fi

# ---------- XDG user directories (nice-to-have) ----------
if user_exists "$USERNAME"; then
  log "Ensuring xdg-user-dirs for $USERNAME"
  sudo -u "$USERNAME" env HOME="/home/$USERNAME" xdg-user-dirs-update || true
fi

# ---------- NVIDIA note (optional) ----------
# If you have NVIDIA and need proper Wayland bits, uncomment:
# pacman -S --noconfirm --needed nvidia nvidia-utils nvidia-settings
# echo "options nvidia_drm modeset=1" > /etc/modprobe.d/nvidia-drm.conf
# mkinitcpio -P

# ---------- MERGE HERE: from your old scripts ----------
# If your previous install.sh/setup.sh/hyprland.sh included extra steps
# (fonts, theming, shell, terminal setup, extra services, etc.),
# paste them below this line. Keep things idempotent where possible.
#
# Example:
# pacman -S --noconfirm --needed zsh zsh-completions starship
# chsh -s /bin/zsh "$USERNAME"
#
# ---------- END MERGE ZONE ----------

log "All done! Reboot to land in SDDM → select 'ml4w-Hyprland'."

