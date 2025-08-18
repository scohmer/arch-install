#!/bin/sh
set -eu

# -------- Config via environment (override when calling) --------
: "${TZ:=America/New_York}"
: "${HOSTNAME:=archlinux}"
: "${USERNAME:=archuser}"
: "${USER_PASSWORD:=changeme}"
: "${ROOT_PASSWORD:=root}"
: "${SUDO_NOPASSWD:=0}"         # 1 for passwordless sudo for wheel
: "${DISK:=}"                   # e.g. /dev/nvme0n1 (passed in by install.sh)
# ----------------------------------------------------------------

echo "==> Beginning chroot configuration"

# 1) Timezone & clock
echo "==> Timezone: $TZ"
ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
hwclock --systohc

# 2) Locale
echo "==> Locale: en_US.UTF-8"
sed -i 's/^[# ]*en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf

# 3) Hostname & hosts
echo "==> Hostname: $HOSTNAME"
printf '%s\n' "$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# 4) mkinitcpio — ensure lvm2 in HOOKS then rebuild
echo "==> mkinitcpio: ensure lvm2 hook"
if ! grep -q '^[[:space:]]*HOOKS=.*lvm2' /etc/mkinitcpio.conf; then
  # Insert lvm2 just before 'filesystems' if not present
  sed -i 's/\(HOOKS=.*\)filesystems/\1lvm2 filesystems/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

# 5) Microcode (intel/amd)
CPU_VENDOR="$(LC_ALL=C lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/,"",$2); print $2}')"
case "$CPU_VENDOR" in
  GenuineIntel) pacman -Sy --noconfirm intel-ucode ;;
  AuthenticAMD) pacman -Sy --noconfirm amd-ucode ;;
  *) echo "==> Unknown CPU vendor ($CPU_VENDOR); skipping microcode package";;
esac

# 6) Bootloader (GRUB)
if [ -d /sys/firmware/efi ] && [ -d /boot/efi ]; then
  echo "==> Installing GRUB (UEFI)"
  pacman -Sy --noconfirm grub efibootmgr
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
else
  echo "==> Installing GRUB (BIOS/legacy)"
  pacman -Sy --noconfirm grub
  if [ -z "${DISK}" ]; then
    echo "ERROR: DISK is not set for BIOS grub-install (e.g., /dev/sda or /dev/nvme0n1)"; exit 1
  fi
  grub-install --target=i386-pc "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# 7) Users & passwords
echo "==> Setting passwords and creating user"
echo "root:${ROOT_PASSWORD}" | chpasswd
id -u "$USERNAME" >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# 8) Sudo policy
if [ "$SUDO_NOPASSWD" = "1" ]; then
  echo "==> Enabling passwordless sudo for wheel"
  echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/99-wheel-nopasswd
  chmod 440 /etc/sudoers.d/99-wheel-nopasswd
else
  echo "==> Enabling standard sudo for wheel"
  sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
fi

# 9) Networking & services
echo "==> Enabling services"
pacman -Sy --noconfirm networkmanager openssh reflector sudo vim
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable systemd-timesyncd
systemctl enable fstrim.timer

# 10) Pacman quality-of-life
echo "==> Pacman: enable Color & ParallelDownloads"
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = .*/ParallelDownloads = 10/' /etc/pacman.conf

echo "==> Setup complete. You can exit chroot and reboot."
