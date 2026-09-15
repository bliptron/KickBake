# KickBake manual disk selection.
# Anaconda's text UI is tmux-managed and actively redraws the console, so
# raw writes to /dev/console fight it (jumbled output). This launcher puts
# the interactive selection on its OWN screen: a dedicated tmux window when
# tmux is available (the normal case), the raw console otherwise.
#
# Flow (plans/MENUS.md):
#   single disk -> "this disk will be used for host + data" confirmation
#   multi disk  -> pick the host disk; every other eligible disk joins the
#                  pool pool (one Btrfs filesystem spanning those disks)
#   then        -> unified layout readout -> typed 'erase' confirmation ->
#                  write /tmp/kickbake-storage.ks -> anaconda continues
#                  unattended.
# 'exit' at any prompt aborts the install gracefully: nothing is ever
# written, the machine powers off.
#
# Fail-closed: no eligible disk, invalid input, EOF or a confirmation
# mismatch powers the machine off. Only anaconda's clearpart destroys
# data, after the UI reports success.

CONS=/dev/console
LOG=/tmp/kickbake-pre.log
FRAG=/tmp/kickbake-storage.ks
ABORT=/tmp/kickbake-abort
UI=/tmp/kickbake-ui.sh

say() { echo "$*" | tee -a "$LOG" > "$CONS"; }
die() {
    say "KickBake: $*"
    say "KickBake: nothing was written to any disk. Powering off."
    sleep 15
    poweroff
    sleep 999   # if poweroff failed, halt here rather than continue
}

rm -f "$ABORT"

# ---- the interactive UI, launched on its own screen --------------------
cat > "$UI" <<'UIEOF'
# KickBake disk selection UI. stdio is attached to a dedicated screen
# (a tmux window, or the console as fallback) by the launcher.
# Screens follow plans/MENUS.md.
FRAG=/tmp/kickbake-storage.ks
ABORT=/tmp/kickbake-abort
LOG=/tmp/kickbake-pre.log

trap 'touch "$ABORT"' EXIT      # the launcher must never wait on a dead UI

printf '\033[H\033[2J'
say() { echo "$*"; echo "$*" >> "$LOG"; }
die() {
    say "======================================================"
    say "KickBake: $*"
    say "KickBake: nothing was written to any disk."
    say "KickBake: closing now -- the machine powers off."
    say "======================================================"
    sleep 15
    touch "$ABORT"
    poweroff
    sleep 999
}
quit() {
    say ""
    say "KickBake: exited at operator request."
    say "KickBake: nothing was written to any disk."
    say "KickBake: closing now -- the machine powers off."
    sleep 15
    touch "$ABORT"
    poweroff
    sleep 999
}

# Eligible = whole disk under /sys/block that is not removable, not the
# install medium (Fedora-E-dvd* label), not a pseudo-device, and at least
# 24 GiB. Disk TYPE never matters: NVMe, SATA, SCSI/SAS/pvscsi, VirtIO and
# MMC all surface here by their kernel name -- the eligible set is defined
# by exclusions and the size floor only, never by a name whitelist.
MIN_DISK_MIB=24576   # 24 GiB eligibility floor (every scenario)

MEDIADISK=""
for n in $(lsblk -rno NAME,LABEL 2>/dev/null | awk '$2 ~ /^Fedora-E-dvd/ {print $1}'); do
    d=$(lsblk -rno PKNAME "/dev/$n" 2>/dev/null | head -1)
    MEDIADISK="$MEDIADISK ${d:-$n}"
done

eligible() {
    local n="$1" base="/sys/block/$1" why
    [ -d "$base" ] || { echo "skip $n: not in /sys/block" >>"$LOG"; return 1; }
    case "$n" in
        loop*|ram*|dm-*|zram*|sr*|md*|fd*|nbd*) why="pseudo-device";;
    esac
    if [ -n "$why" ]; then echo "skip $n: $why" >>"$LOG"; return 1; fi
    # Only an EXPLICIT removable=1 excludes. NVMe namespaces have no
    # 'removable' attribute at all -- missing must mean fixed.
    if [ "$(cat "$base/removable" 2>/dev/null)" = "1" ]; then
        echo "skip $n: removable" >>"$LOG"; return 1
    fi
    # /sys/block/X/size is in 512-byte sectors -- convert to MiB before
    # comparing against the floor (MIN_DISK_MIB is MiB, not sectors).
    if ! [ "$(( $(cat "$base/size" 2>/dev/null || echo 0) / 2048 ))" \
          -ge "$MIN_DISK_MIB" ] 2>/dev/null; then
        echo "skip $n: below the 24 GiB eligibility floor" >>"$LOG"; return 1
    fi
    local m
    for m in $MEDIADISK; do
        if [ "$m" = "$n" ]; then
            echo "skip $n: install medium" >>"$LOG"; return 1
        fi
    done
    return 0
}

# MiB -> aligned "32 GiB" / "1  TiB" (unit column stays put)
fmt_size() {
    local gib=$(( $1 / 1024 ))
    if [ "$gib" -ge 1024 ]; then
        printf '%-2s %s' "$(( gib / 1024 ))" "TiB"
    else
        printf '%-2s %s' "$gib" "GiB"
    fi
}

# ---- enumerate eligible disks -------------------------------------------
DISKS=()
COUNT=0
for p in /sys/block/*/; do
    b=$(basename "$p")
    eligible "$b" || continue
    COUNT=$((COUNT + 1))
    DISKS+=("$b")
done

[ "$COUNT" -ge 1 ] || die "no eligible disks found."

# ---- screen 1: pick the host disk (plans/MENUS.md) ----------------------
if [ "$COUNT" -eq 1 ]; then
    say "This disk will be used for host + data:"
    say ""
    say " $(printf '%-3s %-13s %6s  %s' "[1]" "/dev/${DISKS[0]}" \
        "$(lsblk -rno SIZE "/dev/${DISKS[0]}" 2>/dev/null | head -1)" \
        "$(lsblk -rno MODEL "/dev/${DISKS[0]}" 2>/dev/null | head -1 | sed 's/\\x20/ /g' | cut -c1-40)")"
    say ""
    say "THE WHOLE DISK WILL BE ERASED."
    say ""
    say "Enter '1' to continue, or 'exit' to quit:"
    say ""
    read -r ans || die "no selection received (EOF)."
    case "$ans" in exit) quit ;; esac
    [ "$ans" = "1" ] || die "invalid selection: '$ans'"
    HOST_IDX=0
else
    say "Select the disk that will contain host:"
    say ""
    for i in "${!DISKS[@]}"; do
        say " $(printf '%-3s %-13s %6s  %s' "[$((i + 1))]" "/dev/${DISKS[$i]}" \
            "$(lsblk -rno SIZE "/dev/${DISKS[$i]}" 2>/dev/null | head -1)" \
            "$(lsblk -rno MODEL "/dev/${DISKS[$i]}" 2>/dev/null | head -1 | sed 's/\\x20/ /g' | cut -c1-40)")"
    done
    say ""
    say "All other eligible disks will be used for data."
    say "ALL ELIGIBLE DISKS WILL BE ERASED."
    say ""
    say "Enter the disk NUMBER, or 'exit' to quit:"
    say ""
    read -r ans || die "no selection received (EOF)."
    case "$ans" in exit) quit ;; esac
    case "$ans" in ''|*[!0-9]*) die "invalid selection: '$ans'" ;; esac
    [ "$ans" -ge 1 ] && [ "$ans" -le "$COUNT" ] || die "selection out of range: $ans"
    HOST_IDX=$((ans - 1))
fi
DISK=${DISKS[$HOST_IDX]}

# ---- sizing rules (agreed spec; unchanged) ------------------------------
#   E1  only disks >= 24 GiB are eligible -- in every scenario.
#   R1  EFI + /boot fixed at 1 GiB each, on the host disk (UKI preparation)
#   R4  host = 25% of the disk, rounded UP, then quantized to a
#       power-of-2 step (~ disk/16) so sizes stay on clean steps
#       (owner-provided calc_partition; stress-tested monotonic)
#   R3  host >= 16 GiB -- empirically proven: the transaction peak
#       needs ~13 GiB usable; a 16 GiB host installs, a 12 GiB one does not
#   R5  host <= 256 GiB
#   R2  pool = the remainder: the host disk's leftover (single disk), or
#       every OTHER eligible disk in full (multi disk, one Btrfs pool)
#   R6  multi disk: the host disk is used 100% for host -- HOST = the
#       whole disk after EFI + /boot; the pool lives on the other disks
SECTORS=$(cat "/sys/block/$DISK/size" 2>/dev/null || echo 0)
DISK_MIB=$(( SECTORS * 512 / 1048576 ))

calc_partition() {
    local disk=$1
    # 25% of the disk, rounded up
    local target=$(( (disk + 3) / 4 ))
    # granularity: a quarter of the target
    local raw_step=$(( target / 4 ))
    (( raw_step < 1 )) && raw_step=1
    # next power of two >= raw_step (bitwise round-up)
    local step=$(( raw_step - 1 ))
    (( step |= step >> 1 ))
    (( step |= step >> 2 ))
    (( step |= step >> 4 ))
    (( step |= step >> 8 ))
    (( step |= step >> 16 ))
    (( step |= step >> 32 )) # 64-bit
    (( step++ ))
    # round the target up to the nearest multiple of the step
    local final_partition=$(( ((target + step - 1) / step) * step ))
    echo "$final_partition"
}
if [ "$COUNT" -eq 1 ]; then
    HOST_MIB=$(calc_partition "$DISK_MIB")
    [ "$HOST_MIB" -lt 16384 ]  && HOST_MIB=16384
    [ "$HOST_MIB" -gt 262144 ] && HOST_MIB=262144
else
    # R6  multi disk: the host disk is used 100% for host -- HOST = the
    # whole disk after EFI + /boot; the pool lives on the OTHER disks,
    # so rationing the host disk would strand its remainder unused.
    HOST_MIB=$(( DISK_MIB - 2048 ))
fi

# pool members: the host disk alone (single), or every OTHER eligible
# disk in full (multi) -- one Btrfs pool spanning those member partitions.
DATADISKS=()
if [ "$COUNT" -eq 1 ]; then
    DATADISKS=("$DISK")
else
    for i in "${!DISKS[@]}"; do
        [ "$i" -eq "$HOST_IDX" ] || DATADISKS+=("${DISKS[$i]}")
    done
fi

data_mib_for() {  # pool capacity on a member disk, MiB
    local d="$1" mib
    mib=$(( $(cat "/sys/block/$d/size" 2>/dev/null || echo 0) * 512 / 1048576 ))
    if [ "$d" = "$DISK" ]; then
        echo $(( mib - 2048 - HOST_MIB ))   # after EFI + /boot + host
    else
        echo "$mib"                          # the whole disk
    fi
}

# ---- screen 2: the unified layout, then the typed confirmation ----------
say ""
say "KickBake: layout"
say ""
say "  host:"
say "    $(fmt_size "$HOST_MIB")    /dev/$DISK"
say ""
say "  data:"
for d in "${DATADISKS[@]}"; do
    say "    $(fmt_size "$(data_mib_for "$d")")    /dev/$d"
done
say ""
say "ALL partitions and data on the disk(s) above will be wiped."
say ""
say "Enter 'erase' to confirm, or 'exit' to quit:"
say ""
read -r conf || die "no confirmation received (EOF)."
conf=$(printf '%s' "$conf" | tr '[:upper:]' '[:lower:]')
case "$conf" in exit) quit ;; esac
[ "$conf" = "erase" ] || die "confirmation was not 'erase' ('$conf') -- aborting."

# ---- the storage fragment (single source for anaconda) ------------------
CSV="$DISK"
for d in "${DATADISKS[@]}"; do
    [ "$d" = "$DISK" ] || CSV="$CSV,$d"
done

{
    echo "# Generated by the KickBake %pre disk selection (host: /dev/$DISK)"
    echo "ignoredisk --only-use=$CSV"
    echo "clearpart --all --initlabel --drives=$CSV"
    echo ""
    echo "# EFI + /boot: fixed 1 GiB each, on the host disk (UKI preparation)"
    echo "part /boot/efi  --fstype=efi   --size=1024 --ondisk=$DISK"
    echo "part /boot      --fstype=ext4  --size=1024 --ondisk=$DISK"
    echo ""
    echo "# host Btrfs filesystem (replaceable machine state)"
    if [ "$COUNT" -eq 1 ]; then
        echo "part btrfs.host --fstype=btrfs --size=$HOST_MIB --ondisk=$DISK"
    else
        echo "part btrfs.host --fstype=btrfs --size=1024 --grow --ondisk=$DISK"
    fi
    echo "btrfs none --label=host btrfs.host"
    echo ""
    echo "# pool Btrfs filesystem (persistent user/project state)"
    if [ "$COUNT" -eq 1 ]; then
        echo "part btrfs.data --fstype=btrfs --size=1024 --grow --ondisk=$DISK"
        echo "btrfs none --label=pool btrfs.data"
    else
        MEMBERS=""
        IDX=0
        for d in "${DATADISKS[@]}"; do
            IDX=$((IDX + 1))
            echo "part btrfs.data$IDX --fstype=btrfs --size=1024 --grow --ondisk=$d"
            MEMBERS="$MEMBERS btrfs.data$IDX"
        done
        echo "btrfs none --label=pool$MEMBERS"
    fi
    echo ""
    echo "# Logical layouts, LABEL-based (single source: this fragment)"
    echo "btrfs /     --subvol --name=root LABEL=host"
    echo "btrfs /home --subvol --name=home LABEL=host"
    echo "btrfs /data --subvol --name=data LABEL=pool"
} > "$FRAG"

say ""
say "KickBake: target accepted -- continuing unattended."
say "KickBake: storage fragment written. This window closes now."
sleep 3
UIEOF

# ---- launch the UI on its own screen ------------------------------------
if command -v tmux >/dev/null 2>&1 && [ -n "${TMUX:-}" ]; then
    say "KickBake: disk selection opened in its own window."
    tmux new-window -n "KickBake disk selection" "bash $UI"
    while [ ! -e "$FRAG" ] && [ ! -e "$ABORT" ]; do
        sleep 1
    done
else
    say "KickBake: tmux not available -- selection runs on this console."
    bash "$UI" < "$CONS" > "$CONS" 2>&1
fi

# ---- evaluate the outcome (FRAG wins over ABORT by design) --------------
if [ -e "$FRAG" ]; then
    say "KickBake: target disk selected -- continuing unattended."
else
    die "selection ended without a target disk (operator exit)."
fi
