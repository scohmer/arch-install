#!/usr/bin/env bash
# One-shot Arch Linux installation (UEFI + LVM on one disk) with GNOME Desktop
set -Eeuo pipefail

msg(){ echo -e "\n==> $*\n"; }
err(){ echo -e "\nERROR: $*\n" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || err "Missing tool '$1'"; }

[ -d /sys/firmware/efi/efivars ] || err "Run in UEFI mode."

# Check required tools
REQUIRED_TOOLS=(sgdisk lsblk awk sed grep partprobe udevadm mkfs.fat mkfs.ext4 
                pvcreate vgcreate lvcreate vgchange wipefs pacstrap genfstab arch-chroot)
for tool in "${REQUIRED_TOOLS[@]}"; do
    need "$tool"
done

timedatectl set-ntp true || true

# LVM volume definitions: "name:size:mountpoint"
declare -a LVM_VOLUMES=(
    "root:40G:/"
    "var:20G:/var"
    "var_log:8G:/var/log"
    "var_log_audit:2G:/var/log/audit"
    "var_tmp:8G:/var/tmp"
    "tmp:8G:/tmp"
    "opt:10G:/opt"
    "home:50G:/home"
)

get_part_path() {
    local disk="$1" partition_num="$2"
    [[ "$disk" == *"nvme"* || "$disk" == *"mmcblk"* || "$disk" == *"loop"* ]] && 
        echo "${disk}p${partition_num}" || echo "${disk}${partition_num}"
}

select_disk() {
    local diskfile
    diskfile="$(mktemp)"
    
    msg "Available disks"
    lsblk -dnpo NAME,SIZE,MODEL,TYPE | awk '$NF=="disk"{print}' > "$diskfile"
    echo "Available disks:"
    awk '{sub(/ disk$/,""); printf("  %d) %s\n", NR, $0)}' "$diskfile"
    
    local count
    count="$(wc -l < "$diskfile")"
    [ "$count" -gt 0 ] || err "No disks found."
    
    while :; do
        printf "Select an available disk [1-%s]: " "$count"
        IFS= read -r choice
        case "$choice" in
            ''|*[!0-9]*) echo "Please enter a number between 1 and $count." ;;
            *)
                if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
                    DISK="$(sed -n "${choice}p" "$diskfile" | awk '{print $1}')"
                    rm -f "$diskfile"
                    break
                else 
                    echo "Please enter a number between 1 and $count."
                fi
                ;;
        esac
    done
    
    echo "You selected: $DISK"
    printf "This will modify %s. Are you sure? [yes/NO] " "$DISK"
    read -r c1; [ "$c1" = "yes" ] || { echo "Aborted."; exit 1; }
    printf "Type 'YES' to continue: "
    read -r c2; [ "$c2" = "YES" ] || { echo "Aborted."; exit 1; }
}

cleanup_disk() {
    msg "Preparing disk and partitioning"
    vgchange -an arch >/dev/null 2>&1 || true
    vgremove -ff -y arch >/dev/null 2>&1 || true
    swapoff -a || true
    umount -R /mnt 2>/dev/null || true
    
    dd if=/dev/zero of="$DISK" bs=1M count=16 oflag=direct,dsync status=none || true
}

create_partitions() {
    sgdisk -Z "$DISK" || true
    sgdisk -o "$DISK"
    sgdisk -n1:0:+600M -t1:ef00 -c1:"EFI"  "$DISK"
    sgdisk -n2:0:+1G   -t2:8300 -c2:"BOOT" "$DISK"
    sgdisk -n3:0:0     -t3:8e00 -c3:"LVM"  "$DISK"
    partprobe "$DISK" || true
    udevadm settle
    
    # Wait for partitions to appear
    local attempts=25
    for ((i=1; i<=attempts; i++)); do
        P_ESP="$(get_part_path "$DISK" 1)"
        P_BOOT="$(get_part_path "$DISK" 2)"
        P_LVM="$(get_part_path "$DISK" 3)"
        [[ -b "$P_ESP" && -b "$P_BOOT" && -b "$P_LVM" ]] && break
        sleep 0.2
    done
}

setup_filesystems() {
    msg "Purging old signatures"
    vgchange -an arch >/dev/null 2>&1 || true
    
    local partitions=("$P_ESP" "$P_BOOT" "$P_LVM")
    for part in "${partitions[@]}"; do
        wipefs -af "$part" || true
    done
    
    msg "Creating filesystems"
    mkfs.fat -F32 "$P_ESP"
    mkfs.ext4 -F -L boot "$P_BOOT"
}

setup_lvm() {
    msg "Setting up LVM"
    pvcreate -ff -y "$P_LVM"
    vgcreate -y arch "$P_LVM"
    
    # Create logical volumes
    for volume_def in "${LVM_VOLUMES[@]}"; do
        IFS=':' read -r name size mountpoint <<< "$volume_def"
        lvcreate -y -L "$size" -n "$name" arch
        mkfs.ext4 -F -L "$name" "/dev/arch/$name"
    done
}

mount_filesystems() {
    msg "Mounting target"
    mkdir -p /mnt
    mount /dev/arch/root /mnt
    
    # Mount filesystems in correct order (parents before children)
    # 1. Mount /boot first
    mkdir -p /mnt/boot
    mount "$P_BOOT" /mnt/boot
    
    # 2. Now create /boot/efi and mount ESP
    mkdir -p /mnt/boot/efi
    mount "$P_ESP" /mnt/boot/efi
    
    # 3. Mount /var
    mkdir -p /mnt/var
    mount /dev/arch/var /mnt/var
    
    # 4. Now create subdirectories in /var and mount child filesystems
    mkdir -p /mnt/var/log
    mount /dev/arch/var_log /mnt/var/log
    
    mkdir -p /mnt/var/log/audit
    mount /dev/arch/var_log_audit /mnt/var/log/audit
    
    mkdir -p /mnt/var/tmp
    mount /dev/arch/var_tmp /mnt/var/tmp
    
    # 5. Mount remaining top-level filesystems
    mkdir -p /mnt/tmp
    mount /dev/arch/tmp /mnt/tmp
    
    mkdir -p /mnt/opt
    mount /dev/arch/opt /mnt/opt
    
    mkdir -p /mnt/home
    mount /dev/arch/home /mnt/home
}


install_system() {
    msg "Pacstrap (base system)"
    pacstrap -K /mnt \
        base linux linux-firmware lvm2 networkmanager vim git base-devel \
        grub efibootmgr gdm pipewire wireplumber xorg-server sudo
    
    msg "Generating fstab"
    genfstab -U /mnt >> /mnt/etc/fstab
    
    msg "Configuring system (chroot)"
    arch-chroot /mnt /bin/bash -euo pipefail <<'CHROOT_EOF'
set -euo pipefail

# Locale / timezone / host
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "arch" > /etc/hostname

# mkinitcpio: include lvm2
sed -i 's/^HOOKS=.*$/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Enable sudo for wheel
sed -i 's/^# *%wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Services
systemctl enable NetworkManager gdm

# GRUB (UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT_EOF
}

setup_users() {
    # Global variable to track created user
    CREATED_USER=""
    
    arch-chroot /mnt /bin/bash <<'USER_EOF'
# Set root password
echo
echo "Set a root password now:"
until passwd </dev/tty; do
    echo "Password setup failed. Please try again."
done

# Create user account
echo
read -rp "Create a new user? Enter username (leave blank to skip): " NEWUSER </dev/tty || true
if [ -n "${NEWUSER}" ]; then
    if ! printf '%s' "${NEWUSER}" | grep -Eq '^[a-z_][a-z0-9_-]*$'; then
        echo "Username '${NEWUSER}' invalid. Skipping user creation."
    else
        id -u "${NEWUSER}" >/dev/null 2>&1 || \
            useradd -m -s /bin/bash -G wheel,audio,video,storage,lp "${NEWUSER}"
        echo "Set password for ${NEWUSER}:"
        until passwd "${NEWUSER}" </dev/tty; do
            echo "Password setup failed. Please try again."
        done
        # Export username for later use
        echo "$NEWUSER" > /tmp/created_user
    fi
fi
USER_EOF
    
    # Capture the created username for later use
    if [ -f /mnt/tmp/created_user ]; then
        CREATED_USER=$(cat /mnt/tmp/created_user)
        rm -f /mnt/tmp/created_user
        export CREATED_USER
    fi
}

install_desktop() {
    arch-chroot /mnt /bin/bash <<'DESKTOP_EOF'
set +e
pacman -Syu --noconfirm

# Install GNOME desktop environment and essential applications
pacman --noconfirm --needed -S \
    gnome gnome-extra gnome-terminal firefox chromium \
    nautilus-extensions file-roller \
    ttf-liberation ttf-dejavu noto-fonts noto-fonts-emoji \
    flatpak

# Enable Flathub repository
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

set -e
DESKTOP_EOF
}

setup_gnome_preferences() {
    # This function sets up basic GNOME preferences for the created user
    if [ -n "${CREATED_USER}" ]; then
        msg "Setting up GNOME preferences for user: ${CREATED_USER}"
        arch-chroot /mnt /bin/bash <<GNOME_EOF
# Switch to the created user and setup basic GNOME preferences
sudo -u ${CREATED_USER} bash -c '
    # Create a convenience script for GNOME customization
    cat > /home/${CREATED_USER}/customize-gnome.sh << "CUSTOMIZE_SCRIPT"
#!/bin/bash
echo "Setting up GNOME preferences..."

# Install GNOME extensions via Flatpak (optional)
echo "Installing GNOME Extensions Manager..."
flatpak install -y flathub com.mattjakeman.ExtensionManager

# Set up some basic GNOME Shell preferences
# Note: These require a GNOME session to be active, so they are provided as reference
cat > /home/${CREATED_USER}/.gnome-setup-commands << "SETUP_COMMANDS"
# Run these commands after logging into GNOME:

# Set dark theme
gsettings set org.gnome.desktop.interface gtk-theme \"Adwaita-dark\"
gsettings set org.gnome.desktop.interface color-scheme \"prefer-dark\"

# Set up dock/dash preferences
gsettings set org.gnome.shell.extensions.dash-to-dock dock-position \"BOTTOM\"
gsettings set org.gnome.shell.extensions.dash-to-dock extend-height false

# Enable tap to click
gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true

# Show battery percentage
gsettings set org.gnome.desktop.interface show-battery-percentage true

# Set favorite apps
gsettings set org.gnome.shell favorite-apps \"['"'"'org.gnome.Nautilus.desktop'"'"', '"'"'firefox.desktop'"'"', '"'"'org.gnome.Terminal.desktop'"'"', '"'"'org.gnome.Software.desktop'"'"']\"
SETUP_COMMANDS

echo "GNOME customization script created!"
echo "Run ~/customize-gnome.sh after first login to install extensions manager."
echo "Then check ~/.gnome-setup-commands for additional customization options."
CUSTOMIZE_SCRIPT
    chmod +x /home/${CREATED_USER}/customize-gnome.sh
'
GNOME_EOF
    else
        msg "No user created - GNOME customization setup skipped"
    fi
}

# Main execution
select_disk
cleanup_disk
create_partitions
setup_filesystems
setup_lvm
mount_filesystems
install_system
setup_users
install_desktop
setup_gnome_preferences

msg "Installation complete! After reboot:
  - Login with your user account at the GDM login screen
  - GNOME desktop environment will be ready to use
  - Run ~/customize-gnome.sh to install Extensions Manager
  - Check ~/.gnome-setup-commands for additional customization options
  
To finish setup:
  - umount -R /mnt
  - reboot
"