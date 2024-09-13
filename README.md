# arch-install

how to install arch

## Pre-installation

1. ensure the iso is in the virtual drive, or that you have made a bootable disk from the iso with balena etcher.
2. ensure you're using UEFI
2. ensure the system that you're booting to has secure boot disabled
3. boot to disk or virtual iso
4. select arch install

## At-the-shell: Pre-installation configuration

1. Prepare the MBR

lsblk (to discover disk device) \
gdisk /dev/<disk device> (for example: /dev/sda)

================================================

Command (? for help): x \
Expert command (? for help): z \
About to wipe out GPT on /dev/sda. Proceed? (Y/N): y \
Blank out MBR? (Y/N): y

2. create and format disk partitions

cgdisk /dev/sda

===============================================

Select the partition type [free space] \
Select [  New   ] \
First sector: <Press Enter> \
Size in sectors or {KMGTP}: 1G \
Hex code or GUID: ef00 \
Enter new partition name: boot

Select the larger partition type [free space] \
Select [  New   ] \
First sector: <Press Enter> \
Size in sectors or {KMGTP}: 16G (sufficient for swap - depends on RAM) \
Hex code or GUID: 8200 \
Enter new partition name: swap

Select the larger partition type [free space] \
Select [  New   ] \
First sector: <Press Enter> \
Size in sectors or {KMGTP}: 200G (some portion of remaining space for system root) \
Hex code or GUID: <Press Enter> \
Enter new partition name: root

Select the larger partition type [free space] \
Select [  New   ] \
First section: <Press Enter> \
Size in sectors or {KMGTP}: <Press Enter> \
Hex code or GUID: <Press Enter> \
Enter new partition name: home

Select [ Write  ] \
Select [ Quit   ]

3. create new filesystems on each partition

mkfs.fat -F32 /dev/sda1 \
mkswap /dev/sda2 \
mkfs.ext4 /dev/sda3 \
mkfs.ext4 /dev/sda4

4. create and mount volumes on each filesystem/partition

mount /dev/sda3 /mnt \
swapon /dev/sda2 \
mount --mkdir /dev/sda1 /mnt/boot \
mount --mkdir /dev/sda4 /mnt/home \
lsblk (to confirm mounts)

5. Set local timezone

timedatectl set-local-rtc yes \
timedatectl set-timezone America/New_York \
hwclock --systohc --utc

timedatectl (to confirm Local and Universal time)

6. Install essential packages.

pacstrap -K /mnt base linux linux-firmware base-devel pacman-contrib

7. Generate file system tables

genfstab -U /mnt >> /mnt/etc/fstab

8. Change into system root for system configuration

arch-chroot

## Post installation configuration

1. Configure local time and localization

ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime \
hwclock --systohc --utc

pacman -S neovim \
which nvim \
ln -sf /usr/bin/nvim /usr/bin/vi

vi /etc/locale.gen \
type /en_US to search for the en_US locale and uncomment it. (en_US.UTF-8) \
locale-gen \
vi /etc/locale.conf \
insert: LANG=en_US.UTF-8 \
export LANG="en_US.UTF-8"

echo "archhostname" > /etc/hostname

2. configure root password and first non-root account and password, edit sudoers

passwd \
set password

useradd -m -g users -G wheel,storage,power -s /bin/bash admin \
passwd admin \ 
set password

set default editor and run visudo \
EDITOR=nvim visudo

uncomment the %wheel line

3. create and edit the boot loader

mount -t efivarfs efivarfs /sys/firmware/efi/efivars \
bootctl install

vi /boot/loader/entries/arch.conf

===============================================

title Arch \
linux /vmlinuz-linux \
initrd /initramfs-linux.img

===============================================

echo "options root=PARTUUID=$(blkid -s PARTUUID -o value /dev/sda3) rw" >> /boot/loader/entries/arch.conf

4. install and enable some essential systemd services

pacman -S dhcpcd \
systemctl enable dhcpcd@ens18 (type ip addr to confirm your network connection for the network interface after the @ symbol)

systemctl enable fstrim.timer

vi /etc/pacman.conf \
uncomment> #[multilib] \
uncomment> #Include = /etc/pacman.d/mirrorlist

pacman -Syu pacman-contrib

cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak \
rankmirrors -n 6 /etc/pacman.d/mirrorlist.bak > /etc/pacman.d/mirrorlist

## Post-configuration & reboot

1. exit chroot \

exit \

2. unmount recursively \

umount -R /mnt \

3. shutdown -r now (or shutdown now if you need to alter your boot order) \