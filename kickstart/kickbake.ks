# Fedora base Kickstart
# Machine birth only. Workstation configuration belongs to Ansible.
#
# %include paths are relative to this directory (resolved at BUILD time
# by builder.py flatten), EXCEPT absolute paths like /tmp/... which are
# RUNTIME includes resolved by Anaconda on the install machine after the
# %pre disk selection runs.

keyboard --vckeymap=gb --xlayouts='gb'
lang en_GB.UTF-8

authselect enable-feature with-fingerprint
firstboot --enable

timezone Europe/London --utc
rootpw --lock

# Payload: the Fedora KDE Plasma Workspaces environment, reproduced
# exactly from the F44 comps environment grouplist, installed from the
# offline repo embedded in the ISO (inst.repo=hd:LABEL=<volid>:/repo).
# Anaconda adds @core automatically. The repo closure (repo_groups in
# config/build.toml) mirrors this list 1:1 so nothing here can miss.
%packages
@^kde-desktop-environment
@admin-tools
@desktop-accessibility
@kde-apps
@kde-desktop
@kde-media
@kde-pim
@libreoffice
%end

# Installed-system boot menu (birth-level bootloader config).
# - stock entry titles: "Fedora Linux (kernel)" per kernel -- no retitling,
#   so future kernel updates arrive consistently named (a retitle here only
#   covered the installed kernel; updated kernels came back stock-named)
# - no rescue entry (grubby's 0-rescue item removed)
# - default=saved + SAVEDEFAULT (last selection persists) and 10s to
#   selection, same as the ISO
# - flat menu (no Advanced submenu); UEFI Firmware Settings entry stays.
%post --log=/root/kickbake-post.log
# The machine boots itself and nothing else: without this, grub2-mkconfig
# runs os-prober and injects entries from OTHER disks -- old KickBake test
# installs reappear in the menu and can even become the default entry.
echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub
grep -q '^GRUB_DEFAULT=' /etc/default/grub \
    && sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub \
    || echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
# Remember the last selected entry across reboots (pairs with DEFAULT=saved).
echo 'GRUB_SAVEDEFAULT=true' >> /etc/default/grub
grep -q '^GRUB_TIMEOUT=' /etc/default/grub \
    && sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/' /etc/default/grub \
    || echo 'GRUB_TIMEOUT=10' >> /etc/default/grub
grep -q '^GRUB_DISABLE_RECOVERY=' /etc/default/grub \
    && sed -i 's/^GRUB_DISABLE_RECOVERY=.*/GRUB_DISABLE_RECOVERY=true/' /etc/default/grub \
    || echo 'GRUB_DISABLE_RECOVERY=true' >> /etc/default/grub
grep -q '^GRUB_DISABLE_SUBMENU=' /etc/default/grub \
    && sed -i 's/^GRUB_DISABLE_SUBMENU=.*/GRUB_DISABLE_SUBMENU=true/' /etc/default/grub \
    || echo 'GRUB_DISABLE_SUBMENU=true' >> /etc/default/grub
rm -f /boot/loader/entries/*0-rescue*.conf
grub2-mkconfig -o /boot/grub2/grub.cfg
[ -d /boot/efi/EFI/fedora ] && grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
# Space reclamation in VMs: weekly TRIM as the deterministic safety net.
# btrfs defaults to discard=async on kernels 6.2+, so the fragment stays
# plain: pykickstart treats extra btrfs tokens as EXTRA DEVICES, which
# made Anaconda's storage plan unsatisfiable ("Kickstart insufficient").
systemctl enable fstrim.timer
%end

# Storage: manual disk selection (plans/Status.md). The %pre script lists
# the eligible disks, requires a typed destructive confirmation and writes
# the storage fragment at runtime; the absolute include below is resolved
# by Anaconda AFTER %pre.
%pre --erroronfail --log=/tmp/kickbake-pre.log
%include select-disk.sh
%end

%include /tmp/kickbake-storage.ks
