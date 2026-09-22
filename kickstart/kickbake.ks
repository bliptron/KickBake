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
efibootmgr
%end

# Installed-system boot menu (birth-level bootloader config).
# - stock entry titles: "Fedora Linux (kernel)" per kernel -- no retitling,
#   so future kernel updates arrive consistently named (a retitle here only
#   covered the installed kernel; updated kernels came back stock-named)
# - no rescue entry (grubby's 0-rescue item removed)
# - default=saved + SAVEDEFAULT (last selection persists)
# - hidden menu: KickBake is single-OS, so the menu stays hidden with a
#   2s timeout; hold SHIFT at boot to reveal it
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
    && sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /etc/default/grub \
    || echo 'GRUB_TIMEOUT=2' >> /etc/default/grub
grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub \
    && sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub \
    || echo 'GRUB_TIMEOUT_STYLE=hidden' >> /etc/default/grub
grep -q '^GRUB_DISABLE_RECOVERY=' /etc/default/grub \
    && sed -i 's/^GRUB_DISABLE_RECOVERY=.*/GRUB_DISABLE_RECOVERY=true/' /etc/default/grub \
    || echo 'GRUB_DISABLE_RECOVERY=true' >> /etc/default/grub
grep -q '^GRUB_DISABLE_SUBMENU=' /etc/default/grub \
    && sed -i 's/^GRUB_DISABLE_SUBMENU=.*/GRUB_DISABLE_SUBMENU=true/' /etc/default/grub \
    || echo 'GRUB_DISABLE_SUBMENU=true' >> /etc/default/grub
rm -f /boot/loader/entries/*0-rescue*.conf
grub2-mkconfig -o /boot/grub2/grub.cfg
[ -d /boot/efi/EFI/fedora ] && grub2-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
# Persistent data filesystem (/data): a fresh subvolume root is always
# root:root 755, which locks out every non-root user. Hand it to the
# first-boot admin -- UID/GID 1000, no user exists yet; Fedora's initial
# setup creates the admin with exactly that identity.
chown 1000:1000 /data
chmod 755 /data
# Give /data a real SELinux label instead of the default_t fallback.
# Conditional: the policy tooling may be absent from the payload, and the
# unconfined admin is not blocked by default_t either way.
if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t var_t "/data(/.*)?" 2>/dev/null || true
    restorecon -RvF /data
fi
# NVRAM hygiene: repeated installs and prior operating systems leave
# stale UEFI boot entries in the firmware (dangling "Fedora Linux" and
# "Windows Boot Manager" entries on a wiped disk). Delete our leftovers
# and those dangling entries, keep the fresh entry, and make it the only
# boot choice. Fail-soft: NVRAM must never fail an install.
if [ -d /sys/firmware/efi ] && command -v efibootmgr >/dev/null 2>&1; then
    current=$(efibootmgr | awk '/\* Fedora Linux/ {print $1}' | tail -1 | tr -d '*')
    efibootmgr | awk '/\* (Fedora Linux|Windows Boot Manager)/ {print $1}' \
        | tr -d '*' | while read -r b; do
            [ "$b" = "$current" ] || efibootmgr -b "$b" -B >/dev/null 2>&1 || true
        done
    [ -n "$current" ] && efibootmgr -o "$current" >/dev/null 2>&1 || true
fi
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
