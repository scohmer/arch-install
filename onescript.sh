#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CONFIG — tweak sizes to control free VG space for future LVM extends
###############################################################################
VG_NAME="arch"

ESP_SIZE="+600MiB"       # UEFI only (FAT32)
BOOT_SIZE="+1GiB"        # /boot outside LVM (ext4)

# LV sizes (any remainder within the VG stays FREE for later lvextend)
ROOT_SIZE="40G"
VAR_SIZE="20G"
VAR_LOG_SIZE="8G"
VAR_LOG_AUDIT_SIZE="2G"
VAR_TMP_SIZE="8G"
TMP_SIZE="8G"
OPT_SIZE="10G"
HOME_SIZE="50G"

# System identity
TZ="${TZ:-America/New_York}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"
HOSTNAME="${HOSTNAME:-archlinux}"

# User
USERNAME="${USERNAME:-archuser}"
USER_PASSWORD="${USER_PASSWORD:-changeme}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
SUDO_NOPASSWD="${SUDO_NOPASSWD:-0}"   # 1 to enable NOPASSWD for wheel

###############################################################################
# HELPERS
###############################################################################
msg(){ printf '\n==> %s\n' "$*"; }

ensure_disk_free() {
  local DEV="$1"
  umount -R /mnt 2>/dev/null || true
  swapoff -a 2>/dev/null || true
  vgchange -an 2>/dev/null || true
  dmsetup remove_all 2>/dev/null || true
  udevadm settle || true
}

rereadpt_wait() {
  local DEV="$1" EXPECT="$2"
  partprobe "$DEV" 2>/dev/null || true
  blockdev --rereadpt "$DEV" 2>/dev/null || true
  udevadm settle || true
  local PSUF=""; case "$DEV" in *[0-9]) PSUF="p" ;; esac
  local n=1
  while [ "$n" -le "$EXPECT" ]; do
    local P="${DEV}${PSUF}${n}"
    local i=0
    while [ $i -lt 80 ] && [ ! -b "$P" ]; do i=$((i+1)); sleep 0.1; done
    n=$((n+1))
  done
}

partition_disk() {
  local DEV="$1"
  sgdisk -Z "$DEV"
  if [ -d /sys/firmware/efi ]; then
    # UEFI: 1=ESP (ef00), 2=/boot (8300), 3=LVM PV (8e00)
    sgdisk -n 1:0:"$ESP_SIZE"   -t 1:ef00 -c 1:"EFI"   "$DEV"
    sgdisk -n 2:0:"$BOOT_SIZE"  -t 2:8300 -c 2:"BOOT"  "$DEV"
    sgdisk -n 3:0:0             -t 3:8e00 -c 3:"LVM"   "$DEV"
    rereadpt_wait "$DEV" 3
  else
    # BIOS: 1=BIOSBOOT (ef02), 2=/boot (8300), 3=LVM PV (8e00)
    sgdisk -n 1:1MiB:+1MiB      -t 1:ef02 -c 1:"BIOSBOOT" "$DEV"
    sgdisk -n 2:0:"$BOOT_SIZE"  -t 2:8300 -c 2:"BOOT"     "$DEV"
    sgdisk -n 3:0:0             -t 3:8e00 -c 3:"LVM"      "$DEV"
    rereadpt_wait "$DEV" 3
  fi
}

calc_parts() {
  local DEV="$1" PSUF=""
  case "$DEV" in *[0-9]) PSUF="p" ;; esac
  if [ -d /sys/firmware/efi ]; then
    printf '%s;%s;%s;%s\n' "${DEV}${PSUF}1" ""             "${DEV}${PSUF}2" "${DEV}${PSUF}3"
  else
    printf '%s;%s;%s;%s\n' ""             "${DEV}${PSUF}1" "${DEV}${PSUF}2" "${DEV}${PSUF}3"
  fi
}

purge_old_metadata() {
  # wipefs old signatures (non-destructive to partition table)
  for p in "$@"; do
    [ -n "$p" ] && [ -b "$p" ] && wipefs -a "$p" || true
  done
}

pick_disk_interactive() {
  local DISKFILE
  DISKFILE="$(mktemp)"
  lsblk -dno NAME,SIZE,TYPE,MODEL | awk '$3=="disk"{print "/dev/"$1, $2, $4}' >"$DISKFILE"
  nl -ba "$DISKFILE" | awk '{printf("  %d) %s %s %s\n", $1, $2, $3, $4)}'
  local COUNT; COUNT="$(wc -l < "$DISKFILE")"
  [ "$COUNT" -gt 0 ] || { echo "No disks found."; exit 1; }
  local choice
  while :; do
    printf "Select an available disk [1-%s]: " "$COUNT"
    read -r choice || true
    case "$choice" in
      ''|*[!0-9]*) echo "Enter a number 1..$COUNT" ;;
      *) [ "$choice" -ge 1 ] && [ "$choice" -le "$COUNT" ] && break || echo "Enter 1..$COUNT" ;;
    esac
  done
  local SELECTED_DEV; SELECTED_DEV="$(sed -n "${choice}p" "$DISKFILE" | awk '{print $1}')"
  rm -f "$DISKFILE"
  echo "$SELECTED_DEV"
}

###############################################################################
# DISK SELECTION (interactive) — type the number of your target drive
###############################################################################
msg "Available disks"
DISK="${DISK:-}"
[ -n "${DISK}" ] || DISK="$(pick_disk_interactive)"
echo "You selected: $DISK"
printf "This will WIPE %s. Type 'YES' to continue: " "$DISK"; read -r AREYOUSURE
[ "$AREYOUSURE" = "YES" ] || { echo "Aborted."; exit 1; }

###############################################################################
# PARTITION → FILESYSTEMS → LVM
###############################################################################
msg "Preparing disk and partitioning"
ensure_disk_free "$DISK"
partition_disk "$DISK"

IFS=';' read -r P_ESP P_BIOS P_BOOT P_LVM <<EOF
$(calc_parts "$DISK")
EOF

msg "Purging any old FS/LVM metadata"
purge_old_metadata "$P_LVM" "$P_BOOT" "${P_ESP:-}"

msg "Creating filesystems"
[ -n "$P_ESP" ] && mkfs.vfat -F32 -n EFI  "$P_ESP"
mkfs.ext4 -L boot "$P_BOOT"

msg "Setting up LVM"
partprobe "$DISK" 2>/dev/null || true
udevadm settle || true
pvcreate -ff -y "$P_LVM"
vgcreate "$VG_NAME" "$P_LVM"

# Create fixed LVs; any remainder in the VG is left FREE (on purpose)
lvcreate -L "$ROOT_SIZE"          -n root          "$VG_NAME"
lvcreate -L "$VAR_SIZE"           -n var           "$VG_NAME"
lvcreate -L "$VAR_LOG_SIZE"       -n var_log       "$VG_NAME"
lvcreate -L "$VAR_LOG_AUDIT_SIZE" -n var_log_audit "$VG_NAME"
lvcreate -L "$VAR_TMP_SIZE"       -n var_tmp       "$VG_NAME"
lvcreate -L "$TMP_SIZE"           -n tmp           "$VG_NAME"
lvcreate -L "$OPT_SIZE"           -n opt           "$VG_NAME"
lvcreate -L "$HOME_SIZE"          -n home          "$VG_NAME"

mkfs.ext4 -L root /dev/"$VG_NAME"/root
mkfs.ext4 -L var  /dev/"$VG_NAME"/var
mkfs.ext4 -L vlog /dev/"$VG_NAME"/var_log
mkfs.ext4 -L vaud /dev/"$VG_NAME"/var_log_audit
mkfs.ext4 -L vtmp /dev/"$VG_NAME"/var_tmp
mkfs.ext4 -L tmp  /dev/"$VG_NAME"/tmp
mkfs.ext4 -L opt  /dev/"$VG_NAME"/opt
mkfs.ext4 -L home /dev/"$VG_NAME"/home

msg "Mounting target"
mount /dev/"$VG_NAME"/root /mnt
mkdir -p /mnt/{boot,boot/efi,var,var/log,var/log/audit,var/tmp,tmp,opt,home}
mount "$P_BOOT" /mnt/boot
[ -n "$P_ESP" ] && mount "$P_ESP" /mnt/boot/efi
mount /dev/"$VG_NAME"/var           /mnt/var
mount /dev/"$VG_NAME"/var_log       /mnt/var/log
mount /dev/"$VG_NAME"/var_log_audit /mnt/var/log/audit
mount /dev/"$VG_NAME"/var_tmp       /mnt/var/tmp
mount /dev/"$VG_NAME"/tmp           /mnt/tmp
mount /dev/"$VG_NAME"/opt           /mnt/opt
mount /dev/"$VG_NAME"/home          /mnt/home

msg "Current mounts under /mnt"
findmnt -Rno TARGET,SOURCE /mnt || true

###############################################################################
# BASE SYSTEM
###############################################################################
msg "Pacstrap base + essentials + SDDM"
pacstrap /mnt base linux linux-firmware lvm2 grub efibootmgr \
  networkmanager openssh sudo vim reflector \
  sddm qt6-wayland

msg "Generate fstab"
genfstab -U /mnt >> /mnt/etc/fstab

###############################################################################
# CHROOT: system config, bootloader, users, services, Hyprland + GPU
###############################################################################
msg "Entering chroot to configure system"
arch-chroot /mnt /bin/bash -e <<'CHROOT'
set -euo pipefail

# Import variables passed from parent by writing them before the heredoc
CHROOT
# Re-open heredoc with variables expanded into the environment of the chroot
arch-chroot /mnt /bin/bash -e <<CHROOT
set -euo pipefail

# ---------------- System identity ----------------
echo "$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
hwclock --systohc

sed -i "s/^#\(${LOCALE} UTF-8\)/\1/" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# ---------------- mkinitcpio with lvm2 ----------------
if grep -q '^HOOKS=' /etc/mkinitcpio.conf; then
  sed -i 's/\(^HOOKS=.*\)block/\1block lvm2/' /etc/mkinitcpio.conf || true
fi
mkinitcpio -P

# ---------------- Bootloader (UEFI or BIOS) ----------------
if [ -d /sys/firmware/efi ]; then
  pacman -Sy --noconfirm grub efibootmgr
  mkdir -p /boot/efi
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
else
  pacman -Sy --noconfirm grub
  # The parent script will pass DISK via environment; fall back to guessing root disk
  DISK_GUESS="$(lsblk -no pkname "$(findmnt -no SOURCE /)" | head -n1)"
  [ -n "$DISK" ] || DISK="/dev/${DISK_GUESS}"
  grub-install --target=i386-pc "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# ---------------- Users & sudo ----------------
echo "root:${ROOT_PASSWORD}" | chpasswd
id -u "$USERNAME" >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
if [ "$SUDO_NOPASSWD" = "1" ]; then
  echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/99-wheel-nopasswd
  chmod 440 /etc/sudoers.d/99-wheel-nopasswd
fi

# ---------------- Services ----------------
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable sddm
systemctl set-default graphical.target

# ---------------- Hyprland + desktop stack ----------------
pacman -Sy --noconfirm --needed \
  hyprland xorg-xwayland \
  kitty waybar rofi-wayland wofi \
  pipewire pipewire-alsa pipewire-pulse wireplumber \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  wl-clipboard grim slurp swappy brightnessctl pavucontrol \
  polkit-gnome ttf-dejavu ttf-liberation noto-fonts noto-fonts-emoji

# GPU auto-detect (fallback to mesa)
GPU_LINE="$(lspci -nnk | grep -E 'VGA|3D|Display' | head -n1 || true)"
case "$GPU_LINE" in
  *NVIDIA*|*nVidia*|*GeForce*)
    pacman -Sy --noconfirm --needed nvidia nvidia-utils nvidia-settings
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
    pacman -Sy --noconfirm --needed mesa ;;
esac

# SDDM Wayland config
install -d -m 755 /etc/sddm.conf.d
cat >/etc/sddm.conf.d/10-wayland.conf <<'EOF'
[General]
DisplayServer=wayland
[Wayland]
CompositorCommand=/usr/bin/kwin_wayland --no-lockscreen --no-global-shortcuts
EnableHiDPI=true
EOF

# Minimal Hyprland config for the user (safe starter)
USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
install -d -m 755 "$USER_HOME/.config/hypr"
cat >"$USER_HOME/.config/hypr/hyprland.conf" <<'EOF'
monitor=,preferred,auto,1
exec-once=waybar
exec-once=nm-applet
bind=SUPER,RETURN,exec,kitty
bind=SUPER,Q,killactive
bind=SUPER,ESC,exit
bind=SUPER,D,exec,wofi --show drun
EOF
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"

CHROOT

echo
msg "Install complete. Remove the USB and reboot into SDDM → select Hyprland."

