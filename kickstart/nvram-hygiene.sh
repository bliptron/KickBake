# KickBake NVRAM hygiene -- delete ONLY dangling UEFI boot entries (Option A).
#
# A UEFI boot entry stores the GPT partition GUID it boots from, e.g.
#   HD(1,GPT,12345678-90ab-cdef-1234-567890abcdef,0x800,0x100000)/File(\...)
# After KickBake wipes the eligible disks, entries that pointed at them are
# dangling: their GUID is no longer present on any attached disk. This removes
# exactly those (the documented promise), leaves every live entry alone --
# including an OS on a disk KickBake did not touch -- and moves the freshly
# installed entry (the one whose GUID matches the live /boot/efi partition) to
# the FRONT of the boot order, keeping the other live entries. Entries with no
# GPT path (network/PciRoot) cannot be judged and are left untouched.
# Fail-soft: NVRAM must never fail an install.
#
# Defined as a function so tests/nvram/ can source this file and drive it with
# fake efibootmgr/lsblk/findmnt on PATH -- no firmware required.
kickbake_nvram_hygiene() {
    _kb_present=$(lsblk -rno PARTUUID 2>/dev/null | tr 'A-Z' 'a-z' | grep -v '^$')
    _kb_esp_dev=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null)
    _kb_esp_uuid=$(lsblk -rno PARTUUID "$_kb_esp_dev" 2>/dev/null \
        | head -n1 | tr 'A-Z' 'a-z')

    _kb_fresh=
    while IFS= read -r _kb_line; do
        _kb_num=$(printf '%s' "$_kb_line" | awk '/^Boot[0-9A-Fa-f]+\*/{print $1}')
        [ -n "$_kb_num" ] || continue
        _kb_num=${_kb_num%\*}
        _kb_num=${_kb_num#Boot}
        _kb_guid=$(printf '%s' "$_kb_line" \
            | grep -oiE 'GPT,[0-9a-f-]{36}' | head -n1 | cut -d, -f2 \
            | tr 'A-Z' 'a-z')
        [ -n "$_kb_guid" ] || continue              # no GPT path -> leave it
        if printf '%s\n' "$_kb_present" | grep -qix "$_kb_guid"; then
            if [ -n "$_kb_esp_uuid" ] && [ "$_kb_guid" = "$_kb_esp_uuid" ]; then
                _kb_fresh=$_kb_num                  # freshly installed entry
            fi
        else
            efibootmgr -b "$_kb_num" -B >/dev/null 2>&1 || true   # dangling
        fi
    done <<EOF
$(efibootmgr -v 2>/dev/null)
EOF

    if [ -n "$_kb_fresh" ]; then
        _kb_order=$(efibootmgr 2>/dev/null \
            | awk -F'[: ]+' '/^BootOrder:/{print $2}')
        _kb_rest=$(printf '%s' "$_kb_order" | tr ',' '\n' \
            | grep -v "^0*${_kb_fresh}$" | grep -v '^$' | tr '\n' ',')
        _kb_rest=${_kb_rest%,}
        if [ -n "$_kb_rest" ]; then
            efibootmgr -o "${_kb_fresh},${_kb_rest}" >/dev/null 2>&1 || true
        else
            efibootmgr -o "$_kb_fresh" >/dev/null 2>&1 || true
        fi
    fi

    unset _kb_present _kb_esp_dev _kb_esp_uuid _kb_line _kb_num _kb_guid \
          _kb_fresh _kb_order _kb_rest 2>/dev/null || true
}
