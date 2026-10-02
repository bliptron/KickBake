#!/usr/bin/env bash
# Rootless compose of the offline kickstart ISO (runs INSIDE the
# kickbake-builder container; invoked by kickbake.py).
#
#   compose-offline.sh <stage.iso> <final.iso> [grub_password]
#
# stage.iso : output of `mkksiso --skip-mkefiboot ...` -- kickstart and the
#             offline repo are already grafted, tree grub.cfg files already
#             carry inst.ks=/inst.repo= kernel args.
# final.iso : destination -- same as stage but with a REBUILT embedded EFI
#             system partition, so UEFI boots also see the kickstart args.
#             (mkksiso would do this with mkefiboot, which needs loop
#             devices -- impossible under rootless podman. We replicate it
#             with mkfs.vfat -C + mcopy, which need no loop devices.)
# grub_password : typed confirmation required to boot the INSTALL entry
#                 (GRUB superusers/password_pbkdf2). Default: kickbake.
set -euo pipefail

STAGE="$1"; FINAL="$2"; GRUB_PW="${3:-kickbake}"

test -f "$STAGE"
rm -f "$FINAL"

W="$(mktemp -d /tmp/esp.XXXXXX)"
trap 'rm -rf "$W"' EXIT

# 1. Extract the (already ks-edited) EFI files from the stage ISO tree.
xorriso -osirrox on -indev "$STAGE" -extract /EFI "$W/EFI" >/dev/null 2>&1
test -f "$W/EFI/BOOT/grub.cfg"

# Sanity: the tree config must already reference the kickstart and repo.
grep -q 'inst.ks='     "$W/EFI/BOOT/grub.cfg"
grep -q 'inst.repo='   "$W/EFI/BOOT/grub.cfg"

# Strip the "Test this media" boot entry (requested: keep the menu lean;
# the media check is redundant -- we verify checksums at build time).
filter_menu() {
    awk '/^menuentry .Test this media/ { skip=1 }
         skip && /^}/ { skip=0; next }
         !skip { print }' "$1" > "$1.new" && mv "$1.new" "$1"
}
xorriso -osirrox on -indev "$STAGE" \
        -extract /boot/grub2/grub.cfg "$W/menu.cfg" >/dev/null 2>&1
test -f "$W/menu.cfg"
filter_menu "$W/EFI/BOOT/grub.cfg"   # ESP copy (UEFI)
filter_menu "$W/menu.cfg"            # tree copy (BIOS)

# The VM renders the TREE /EFI/BOOT/grub.cfg on UEFI boots; keep a lean
# (Test-entry-free) copy of it to write back into the ISO tree below, so
# every boot path shows the same menu. Stock config uses set default="1"
# to auto-run the (now removed) media test entry; with that entry gone
# the default must be the installer. 10s to selection (matches the
# Fedora KDE Plasma media; the Everything netinst default is 60s).
sed -e 's/^set default=.*/set default="0"/' \
    -e 's/^set timeout=.*/set timeout=10/' \
    "$W/EFI/BOOT/grub.cfg" > "$W/efi-tree.cfg"
grep -q 'set default="0"' "$W/efi-tree.cfg"
grep -q 'set timeout=10'  "$W/efi-tree.cfg"

# --- Safety hardening -------------------------------------------------
# The installer entry requires a TYPED passphrase; the short timeout
# means forgotten media reboot-loop harmlessly.
MKPW=$(command -v grub-mkpasswd-pbkdf2 || command -v grub2-mkpasswd-pbkdf2)
test -n "$MKPW"
HASH=$(printf '%s\n%s\n' "$GRUB_PW" "$GRUB_PW" \
       | "$MKPW" 2>/dev/null | grep -o 'grub\.pbkdf2\.sha512\.[^ ]*' | head -1)
test -n "$HASH"

harden_menu() {   # $1=cfg  (ESP copy, UEFI)
    sed -i 's/^set default=.*/set default="0"/; s/^set timeout=.*/set timeout=10/' "$1"
    {   echo 'set superusers="kickbake"'
        echo "password_pbkdf2 kickbake $HASH"
    } | cat - "$1" > "$1.new" && mv "$1.new" "$1"
}
harden_menu "$W/EFI/BOOT/grub.cfg"   # ESP copy (UEFI)

# BIOS/CSM: unsupported by design (README says it). The BIOS tree used to
# mirror the full menu -- a mirage whose every entry failed on selection.
# It is now a single entry that says so and halts.
cat > "$W/menu.cfg" <<'BIOSEOF'
set timeout=30
menuentry 'KickBake requires UEFI -- BIOS/CSM boot is not supported' {
    echo 'This media installs UEFI machines only. Power off, re-enter the'
    echo 'firmware boot menu, and select the UEFI entry for this media.'
    sleep 30
    halt
}
BIOSEOF
grep -q 'requires UEFI' "$W/menu.cfg"

# Guards: lean menus, auth on the installer, BIOS halt entry in place.
grep -q 'Test this media' "$W/EFI/BOOT/grub.cfg" && exit 3
grep -q 'Test this media' "$W/menu.cfg" && exit 3
grep -q 'Test this media' "$W/efi-tree.cfg" && exit 3
grep -q 'superusers="kickbake"' "$W/EFI/BOOT/grub.cfg"
grep -q 'password_pbkdf2' "$W/EFI/BOOT/grub.cfg"
grep -q 'requires UEFI' "$W/menu.cfg"

# 2. Build the fresh ESP image without loop devices.
ESP="$W/efiboot.img"
# NOTE: mkfs.vfat -C takes BLOCKS of 1024 bytes (no suffixes in dosfstools
# 4.2). 40 * 1024 = 40 MiB -- matches mkefiboot's sizing with headroom
# (the original hidden ESP is ~13 MB).
mkfs.vfat -C -n ANACONDA "$ESP" $((40 * 1024)) >/dev/null
# Hard post-condition: the image must be a full 40 MiB. If a future
# dosfstools changed the -C block size the file would be smaller, and the
# verifier's `dd ... bs=2048 count=20480` (kickbake.py) would silently
# truncate. Fail loudly here instead.
test "$(stat -c %s "$ESP")" -ge $((40 * 1024 * 1024))
mcopy -s -Q -i "$ESP" "$W/EFI" ::

# 3. Re-embed as GPT partition 2 -- the same xorriso mechanism mkksiso
#    uses for mkefiboot output: boot replay, then append_partition.
xorriso -indev "$STAGE" -outdev "$FINAL" \
        -boot_image any replay \
        -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$ESP" \
        -update "$W/menu.cfg" /boot/grub2/grub.cfg \
        -update "$W/efi-tree.cfg" /EFI/BOOT/grub.cfg \
        >/dev/null 2>&1
test -f "$FINAL"

# 4. Re-implant the isomd5 checksum (the rewrite invalidated the old one).
implantisomd5 --force "$FINAL" >/dev/null

echo "compose-offline: ESP rebuilt, wrote $(basename "$FINAL")"
