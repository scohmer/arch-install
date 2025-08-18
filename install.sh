#!/bin/sh
set -eu

###############################################################################
# Configurable sizes
###############################################################################
VG_NAME="arch"

ESP_SIZE="+600MiB"    # UEFI only (FAT32)
BOOT_SIZE="+1GiB"     # /boot outside LVM (ext4)

# LV sizes; /home takes the remainder
ROOT_SIZE="40G"
VAR_SIZE="20G"
VAR_LOG_SIZE="8G"
VAR_LOG_AUDIT_SIZE="2G"
VAR_TMP_SIZE="8G"
TMP_SIZE="8G"
OPT_SIZE="10G"

###############################################################################
# Helpers
###############################################################################
msg() { printf '\n==> %s\n' "$*"; }

ensure_disk_free() {
  DEV="$1"
  umount -R /mnt 2>/dev/null || true
  swapoff -a 2>/dev/null || true
  vgchange -an 2>/dev/null || true
  dmsetup remove_all 2>/dev/null || true
  udevadm settle || true
}

# Re-read partition table and wait for N partitions to appear
rereadpt_wait() {
  DEV="$1"; EXPECT="$2"
  partprobe "$DEV" 2>/dev/null || true
  blockdev --rereadpt "$DEV" 2>/dev/null || true
  udevadm settle || true
  case "$DEV" in *[0-9]) PSUF="p" ;; *) PSUF="" ;; esac
  n=1
  while [ "$n" -le "$EXPECT" ]; do
    P="${DEV}${PSUF}${n}"
    i=0
    while [ $i -lt 60 ] && [ ! -b "$P" ]; do i=$((i+1)); sleep 0.1; done
    n=$((n+1))
  done
}

# Create partitions with sgdisk (no fragile math)
partition_disk() {
  DEV="$1"
  UEFI=0; [ -d /sys/firmware/efi ] && UEFI=1

  sgdisk --zap-all "$DEV" 2>/dev/null || true
  wipefs -af "$DEV"

  if [ "$UEFI" -eq 1 ]; then
    # UEFI: 1=ESP (ef00), 2=/boot (8300), 3=LVM PV (8e00)
    sgdisk -n 1:1MiB:"$ESP_SIZE"  -t 1:ef00 -c 1:"ESP"   "$DEV"
    sgdisk -n 2:0:"$BOOT_SIZE"    -t 2:8300 -c 2:"BOOT"  "$DEV"
    sgdisk -n 3:0:0               -t 3:8e00 -c 3:"LVM"   "$DEV"
    rereadpt_wait "$DEV" 3
  else
    # BIOS: 1=BIOS boot (ef02), 2=/boot (8300), 3=LVM PV (8e00)
    sgdisk -n 1:1MiB:+1MiB        -t 1:ef02 -c 1:"BIOSBOOT" "$DEV"
    sgdisk -n 2:0:"$BOOT_SIZE"    -t 2:8300 -c 2:"BOOT"     "$DEV"
    sgdisk -n 3:0:0               -t 3:8e00 -c 3:"LVM"      "$DEV"
    rereadpt_wait "$DEV" 3
  fi
}

calc_parts() {
  DEV="$1"
  case "$DEV" in *[0-9]) PSUF="p" ;; *) PSUF="" ;; esac
  if [ -d /sys/firmware/efi ]; then
    P_ESP="${DEV}${PSUF}1"
    P_BOOT="${DEV}${PSUF}2"
    P_LVM="${DEV}${PSUF}3"
    P_BIOS=""
  else
    P_ESP=""
    P_BOOT="${DEV}${PSUF}2"
    P_LVM="${DEV}${PSUF}3"
    P_BIOS="${DEV}${PSUF}1"
  fi
  printf '%s;%s;%s;%s\n' "$P_ESP" "$P_BIOS" "$P_BOOT" "$P_LVM"
}

###############################################################################
# Disk selection menu
###############################################################################
DISKFILE="$(mktemp)"; trap 'rm -f "$DISKFILE"' EXIT

lsblk -dnpo NAME,SIZE,MODEL,TYPE | awk '$NF=="disk"{print}' > "$DISKFILE"

echo "Available disks:"
awk '{sub(/ disk$/,""); printf("  %d) %s\n", NR, $0)}' "$DISKFILE"

COUNT="$(wc -l < "$DISKFILE")"
[ "$COUNT" -gt 0 ] || { echo "No disks found."; exit 1; }

while :; do
  printf "Select an available disk [1-%s]: " "$COUNT"
  IFS= read -r choice
  case "$choice" in
    ''|*[!0-9]*) echo "Please enter a number between 1 and $COUNT." ;;
    *)
      if [ "$choice" -ge 1 ] && [ "$choice" -le "$COUNT" ]; then
        SELECTED_DEV="$(sed -n "${choice}p" "$DISKFILE" | awk '{print $1}')"
        break
      else
        echo "Please enter a number between 1 and $COUNT."
      fi
      ;;
  esac
done

echo "You selected: $SELECTED_DEV"
printf "This will modify %s. Are you sure? [yes/NO] " "$SELECTED_DEV"; read -r c1; [ "$c1" = "yes" ] || { echo "Aborted."; exit 1; }
printf "Type 'YES' to continue: "; read -r c2; [ "$c2" = "YES" ] || { echo "Aborted."; exit 1; }

###############################################################################
# Partitioning
###############################################################################
msg "Preparing disk and partitioning"
ensure_disk_free "$SELECTED_DEV"
partition_disk "$SELECTED_DEV"

IFS=';' read -r P_ESP P_BIOS P_BOOT P_LVM <<EOF
$(calc_parts "$SELECTED_DEV")
EOF

msg "Partition map"
lsblk -no NAME,TYPE,SIZE "$SELECTED_DEV" || true

###############################################################################
# Filesystems + LVM
###############################################################################
msg "Creating filesystems"
[ -n "$P_ESP" ] && mkfs.vfat -F32 -n EFI "$P_ESP"
mkfs.ext4 -L boot "$P_BOOT"

msg "Setting up LVM"
pvcreate -ff -y "$P_LVM"
vgchange -an "$VG_NAME" 2>/dev/null || true
vgcreate "$VG_NAME" "$P_LVM"

lvcreate -L "$ROOT_SIZE"          -n root          "$VG_NAME"
lvcreate -L "$VAR_SIZE"           -n var           "$VG_NAME"
lvcreate -L "$VAR_LOG_SIZE"       -n var_log       "$VG_NAME"
lvcreate -L "$VAR_LOG_AUDIT_SIZE" -n var_log_audit "$VG_NAME"
lvcreate -L "$VAR_TMP_SIZE"       -n var_tmp       "$VG_NAME"
lvcreate -L "$TMP_SIZE"           -n tmp           "$VG_NAME"
lvcreate -L "$OPT_SIZE"           -n opt           "$VG_NAME"
lvcreate -l 100%FREE              -n home          "$VG_NAME"

mkfs.ext4 -L root          "/dev/$VG_NAME/root"
mkfs.ext4 -L var           "/dev/$VG_NAME/var"
mkfs.ext4 -L var_log       "/dev/$VG_NAME/var_log"
mkfs.ext4 -L var_log_audit "/dev/$VG_NAME/var_log_audit"
mkfs.ext4 -L var_tmp       "/dev/$VG_NAME/var_tmp"
mkfs.ext4 -L tmp           "/dev/$VG_NAME/tmp"
mkfs.ext4 -L opt           "/dev/$VG_NAME/opt"
mkfs.ext4 -L home          "/dev/$VG_NAME/home"

###############################################################################
# Mount in strict order, creating mount points before and after parents
###############################################################################
msg "Creating mount directory tree (pre-create)"
mkdir -p /mnt \
         /mnt/boot /mnt/boot/efi \
         /mnt/var /mnt/var/log /mnt/var/log/audit /mnt/var/tmp \
         /mnt/tmp /mnt/opt /mnt/home

msg "Mounting filesystems (ordered)"
# 1) Root first
mount /dev/"$VG_NAME"/root /mnt

# Ensure children exist inside the mounted root
mkdir -p /mnt/boot /mnt/boot/efi \
         /mnt/var /mnt/var/log /mnt/var/log/audit /mnt/var/tmp \
         /mnt/tmp /mnt/opt /mnt/home

# 2) /boot (real partition), then /boot/efi (if UEFI)
mount "$P_BOOT" /mnt/boot
[ -n "${P_ESP:-}" ] && { mkdir -p /mnt/boot/efi; mount "$P_ESP" /mnt/boot/efi; }

# 3) /var (parent), then its children
mount /dev/"$VG_NAME"/var /mnt/var
mkdir -p /mnt/var/log /mnt/var/log/audit /mnt/var/tmp
mount /dev/"$VG_NAME"/var_log        /mnt/var/log
mount /dev/"$VG_NAME"/var_log_audit  /mnt/var/log/audit
mount /dev/"$VG_NAME"/var_tmp        /mnt/var/tmp

# 4) Other top-level mounts
mount /dev/"$VG_NAME"/tmp  /mnt/tmp
mount /dev/"$VG_NAME"/opt  /mnt/opt
mount /dev/"$VG_NAME"/home /mnt/home

echo
msg "Current mounts under /mnt"
findmnt -Rno TARGET,SOURCE /mnt || true

echo
msg "Next steps"
cat <<'EOT'
  pacstrap /mnt base linux linux-firmware lvm2
  genfstab -U /mnt >> /mnt/etc/fstab
  arch-chroot /mnt

  UEFI + GRUB:
    pacman -S grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
    grub-mkconfig -o /boot/grub/grub.cfg

  BIOS + GRUB (no ESP):
    grub-install --target=i386-pc /dev/DEVICE
    grub-mkconfig -o /boot/grub/grub.cfg

  Optional fstab hardening:
    - /tmp, /var/tmp: nodev,nosuid,noexec
    - /var/log, /var/log/audit: nodev,nosuid
EOT
