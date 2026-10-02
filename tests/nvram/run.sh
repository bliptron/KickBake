#!/bin/sh
# Tier 0 host-side test for kickbake_nvram_hygiene() (D-5 / Option A).
#
#   sh tests/nvram/run.sh
#
# Requires only /bin/sh plus the usual coreutils/grep/awk. It sources the real
# logic from kickstart/nvram-hygiene.sh and drives it with fake efibootmgr,
# lsblk and findmnt on PATH, so no firmware and no VM are involved. This is the
# cheap first gate: prove the parsing before spending VM time (Tier 1).
#
# A UEFI entry stores the GPT partition GUID it boots from. "Dangling" means
# that GUID is not among the currently present PARTUUIDs. The logic must:
#   * delete dangling entries (whatever their description);
#   * keep live entries (including an OS on an untouched disk);
#   * keep entries with no GPT path (cannot be judged);
#   * move the fresh entry (GUID == /boot/efi PARTUUID) to the FRONT of the
#     boot order and keep the other live entries after it.

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
logic="$root/kickstart/nvram-hygiene.sh"
fakes="$here/fake-bin"
[ -f "$logic" ] || { echo "missing logic file: $logic" >&2; exit 1; }
[ -d "$fakes" ] || { echo "missing fake-bin dir: $fakes" >&2; exit 1; }
chmod +x "$fakes"/* 2>/dev/null || true

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
check() { # description expected actual
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); echo "ok   - $1"
    else
        fail=$((fail + 1)); echo "FAIL - $1"
        echo "         expected: [$2]"
        echo "         actual:   [$3]"
    fi
}

# Run the real logic with the harness's fake tools and state files.
run_logic() { # $1=state $2=order $3=partuuids $4=devmap $5=espdev
    KICKBAKE_FAKE_STATE="$1" KICKBAKE_FAKE_ORDER="$2" \
    KICKBAKE_FAKE_PARTUUIDS="$3" KICKBAKE_FAKE_DEVMAP="$4" \
    KICKBAKE_FAKE_ESPDEV="$5" \
        PATH="$fakes:$PATH" sh -c ". '$logic'; kickbake_nvram_hygiene"
}

ids() { cut -f1 "$1" | sed 's/^[Bb][Oo][Oo][Tt]//' | tr '\n' ',' | sed 's/,$//'; }

# ---------------------------------------------------------------------------
# Scenario 1: the full mixed case.
#   0000 dangling Windows (disk detached)      -> delete
#   0001 Fedora on the live ESP (fresh)        -> keep + promote
#   0002 Windows on a present, ineligible disk -> keep
#   0003 dangling Fedora (old wiped install)   -> delete
#   0004 network entry, no GPT path            -> keep (cannot judge)
# ---------------------------------------------------------------------------
s1="$tmp/state1"; o1="$tmp/order1"
cat > "$s1" <<'EOF'
Boot0000	Windows Boot Manager	HD(1,GPT,cccccccc-0000-0000-0000-000000000003,0x800,0x100000)/File(\EFI\Microsoft\Boot\bootmgfw.efi)
Boot0001	Fedora	HD(1,GPT,aaaaaaaa-0000-0000-0000-000000000001,0x800,0x100000)/File(\EFI\fedora\shimx64.efi)
Boot0002	Windows Boot Manager	HD(1,GPT,bbbbbbbb-0000-0000-0000-000000000002,0x800,0x100000)/File(\EFI\Microsoft\Boot\bootmgfw.efi)
Boot0003	Fedora Linux	HD(1,GPT,dddddddd-0000-0000-0000-000000000004,0x800,0x100000)/File(\EFI\fedora\shimx64.efi)
Boot0004	UEFI: PXE IPv4	PciRoot(0x0)/Pci(0x1c,0x0)/MAC(001122334455)/IPv4(0.0.0.0)
EOF
printf '0000,0001,0002,0003,0004\n' > "$o1"
printf 'aaaaaaaa-0000-0000-0000-000000000001\nbbbbbbbb-0000-0000-0000-000000000002\n' \
    > "$tmp/parts1"
printf '/dev/sda1\taaaaaaaa-0000-0000-0000-000000000001\n/dev/sdc1\tbbbbbbbb-0000-0000-0000-000000000002\n' \
    > "$tmp/devmap1"
run_logic "$s1" "$o1" "$tmp/parts1" "$tmp/devmap1" /dev/sda1
check "SC1 deletes only the dangling entries" "0001,0002,0004" "$(ids "$s1")"
check "SC1 fresh entry promoted, live entries kept" "0001,0002,0004" "$(cat "$o1")"

# ---------------------------------------------------------------------------
# Scenario 2: fresh entry is not first to begin with (realistic -- every id in
# the boot order exists at the start, like a real machine).
#   0000 dangling, 0001 fresh, 0002 live, 0004 no-GPT; order starts 0002-first.
# ---------------------------------------------------------------------------
s2="$tmp/state2"; o2="$tmp/order2"
cat > "$s2" <<'EOF'
Boot0000	Windows Boot Manager	HD(1,GPT,cccccccc-0000-0000-0000-000000000003,0x800,0x100000)/File(\EFI\Microsoft\Boot\bootmgfw.efi)
Boot0001	Fedora	HD(1,GPT,aaaaaaaa-0000-0000-0000-000000000001,0x800,0x100000)/File(\EFI\fedora\shimx64.efi)
Boot0002	Windows Boot Manager	HD(1,GPT,bbbbbbbb-0000-0000-0000-000000000002,0x800,0x100000)/File(\EFI\Microsoft\Boot\bootmgfw.efi)
Boot0004	UEFI: PXE IPv4	PciRoot(0x0)/Pci(0x1c,0x0)/MAC(001122334455)/IPv4(0.0.0.0)
EOF
printf '0002,0000,0001,0004\n' > "$o2"
run_logic "$s2" "$o2" "$tmp/parts1" "$tmp/devmap1" /dev/sda1
check "SC2 dangling removed despite order" "0001,0002,0004" "$(ids "$s2")"
check "SC2 fresh moved to front, live kept" "0001,0002,0004" "$(cat "$o2")"

# ---------------------------------------------------------------------------
# Scenario 3: no entry points at the ESP -> nothing to promote, order kept.
# ---------------------------------------------------------------------------
s3="$tmp/state3"; o3="$tmp/order3"
cat > "$s3" <<'EOF'
Boot0000	Windows Boot Manager	HD(1,GPT,cccccccc-0000-0000-0000-000000000003,0x800,0x100000)/File(\EFI\Microsoft\Boot\bootmgfw.efi)
Boot0001	Windows Boot Manager	HD(1,GPT,bbbbbbbb-0000-0000-0000-000000000002,0x800,0x100000)/File(\EFI\Microsoft\Boot\bootmgfw.efi)
Boot0002	UEFI: PXE IPv4	PciRoot(0x0)/Pci(0x1c,0x0)/MAC(001122334455)/IPv4(0.0.0.0)
EOF
printf '0000,0001,0002\n' > "$o3"
printf 'bbbbbbbb-0000-0000-0000-000000000002\n' > "$tmp/parts3"
printf '/dev/sda1\teeeeeeee-0000-0000-0000-000000000009\n' > "$tmp/devmap3"
run_logic "$s3" "$o3" "$tmp/parts3" "$tmp/devmap3" /dev/sda1
check "SC3 dangling removed" "0001,0002" "$(ids "$s3")"
check "SC3 boot order untouched (no fresh found)" "0001,0002" "$(cat "$o3")"

# ---------------------------------------------------------------------------
# Scenario 4: no GPT disks at all -> every GPT entry is dangling; no-GPT kept.
# ---------------------------------------------------------------------------
s4="$tmp/state4"; o4="$tmp/order4"
cat > "$s4" <<'EOF'
Boot0000	Fedora	HD(1,GPT,dddddddd-0000-0000-0000-000000000004,0x800,0x100000)/File(\EFI\fedora\shimx64.efi)
Boot0001	UEFI: PXE IPv4	PciRoot(0x0)/Pci(0x1c,0x0)/MAC(001122334455)/IPv4(0.0.0.0)
EOF
printf '0000,0001\n' > "$o4"
: > "$tmp/parts4"
: > "$tmp/devmap4"
run_logic "$s4" "$o4" "$tmp/parts4" "$tmp/devmap4" ""
check "SC4 all GPT entries dangling, no-GPT kept" "0001" "$(ids "$s4")"
check "SC4 boot order pruned to survivors" "0001" "$(cat "$o4")"

# ---------------------------------------------------------------------------
echo ""
echo "nvram-hygiene (Tier 0): $pass passed, $fail failed"
[ "$fail" -eq 0 ]
