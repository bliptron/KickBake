# KickBake

**An opinionated offline installer generator for Fedora KDE Plasma.**

KickBake bakes a fully self-contained, unattended Fedora KDE Plasma installation ISO from the official Fedora Everything netinst: one build command in, one ISO out. Boot it on a machine or VM, pick the disk, type `erase`, and walk away. You come back to a freshly installed, fully offline-provisioned Fedora Plasma system, ready for Ansible to give it its personality.

It is not a distribution, not a framework, and not trying to be popular. It is a tool for people who think about machines the same way: **install media is machine birth; everything after that is something else's job** (in my case, Ansible).

---

## The opinions

KickBake is strongly opinionated. These are features, not limitations to be fixed:

- **Fedora only.** Kickstart, Anaconda and DNF comps are the mechanism, none of it ports to other distributions, and no attempt will be made.
- **KDE Plasma only.** The payload uses Fedora's KDE Plasma Workspaces environment. If you want GNOME, XFCE or anything between, this is not your tool.
- **100% offline at install time.** The ISO embeds the complete package closure (~2300 packages, comps included). No network is used or required.
- **Fresh when you wish it to be.** The offline repo is resolved against Fedora release + updates whenever `repo` is refreshed, so a build made from a freshly refreshed repo is already patched on day one.
- **Manual disk selection. The installer never guesses.** No automatic disk inference, no "it looked like a good target". You choose the disk from a short, informative list and type `erase` to confirm. Ambiguity of any kind powers the machine off with nothing written. On multi-disk machines, the selected disk becomes `host` and every other eligible fixed disk becomes part of `data`; all eligible disks are erased.
- **One storage layout: host + data.** host (root + home) is replaceable machine state; data is the persistent data filesystem. Single concept with a single code path.
- **Fail always close.** Invalid input, EOF, an unexpected condition, a tiny disk, the machine powers off with nothing written. Only an explicit `erase` lets Anaconda touch a disk.
- **No full installer UI.** KickBake asks one disk selection followed by one destructive confirmation, and answers everything else itself. Anaconda's interactive interface is never exposed.
- **Root is locked. No user is pre-created.** Fedora's initial setup collects the admin user at first boot. Machine birth does not include accounts.
- **Boot safety is real.** The installed system boots from a safe-default GRUB; the installer entry is password-protected; and the media announces its build date (`KickBake 26.09.15`) at the boot menu so stale media is immediately obvious.
- **Visible progress, no secrets.** The install proceeds unattended with normal Anaconda progress once the disk is confirmed.

---

## Use cases

- **Test VMs.** Spin up a fresh, fully patched Fedora Plasma machine in minutes. The ISO is a standard hybrid image with no hypervisor-specific dependencies.
- **Homelab and physical machines.** Standard UEFI hardware with a standard NVMe/SATA/SCSI/IDE disk.
- **Wipe-and-repurpose workflows.** When a machine's data is disposable and the disk is the target, KickBake turns reinstalling into a two-prompt operation.
- **Consistent machine birth for configuration management.** Every machine comes out the same way, at the same patch level, with the same storage layout. It's the ideal starting point for Ansible.

**Not for:** dual-boot setups, preserving existing data, other Linux distros, or anyone wanting an installer with 40 screens of options.

---

## Requirements

**Build host:**

- Linux
- Python 3.11+ (stdlib only)
- Rootless Podman
- ~16 GB free (source ISO + repo cache + output)
- Network access whenever the repo is refreshed

**Target machine:**

- **UEFI boot only.** BIOS/CSM firmware is unsupported: the media does
  not boot. Fails by design, not by accident. On virtual machines, set
  the firmware to UEFI at creation time — switching a VM between BIOS
  and UEFI after it has booted can leave the boot chain broken.
- At least one fixed disk ≥ 24 GiB (see the sizing rules).
- Any fixed-disk type works in principle. Enumeration is
  name-agnostic (NVMe, SATA, VirtIO, pvscsi, SCSI, IDE). No whitelist is applied. Proven so far: NVMe, SATA, SCSI and IDE (VMware). VirtIO/pvscsi are untested.

---

## Installation

Clone the repository and enter it:

```bash
git clone https://github.com/bliptron/KickBake
cd KickBake
```

KickBake has no Python package dependencies and does not need to be installed with `pip`. It requires Python 3.11+ and rootless Podman.

Verify the environment:

```bash
python3 kickbake.py doctor
```

If you prefer to manage Python with `uv`:

```bash
uv run --python 3.11 python kickbake.py doctor
```

`doctor` checks the build environment and prepares the required Podman toolchain.

---

## Usage

```bash
python3 kickbake.py doctor    # environment check
python3 kickbake.py repo      # build the offline KDE repo (once; refresh when you want newer packages)
python3 kickbake.py build     # bake the ISO
```

Output:

```
output/fedora-plasma-44.1.7-kickbake-<YY.MM.DD>.iso
output/fedora-plasma-44.1.7-kickbake-<YY.MM.DD>.iso.sha256
output/fedora-plasma-44.1.7-kickbake-<YY.MM.DD>.ks
```

The filename includes today's date (`YY.MM.DD`; same-day rebuilds never overwrite since they gain `-1`, `-2`, ...). The boot menu carries the build date, showing as `KickBake 26.09.22`, so stale media is unmistakable there.

Then: boot the target from the ISO → the disk selection screen lists eligible disks → enter the number → read the layout → type `erase` → the install runs unattended → Fedora's initial setup creates your user at first boot → hand the machine to Ansible or just start using.

---

## The storage rules

KickBake offers exactly one layout, computed from the disk you choose:

| Rule                          | Value                                                                                                                                                                          |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Eligibility                   | whole fixed disks ≥ 24 GiB only                                                                                                                                                |
| EFI                           | 1 GiB, fixed, generous by design, in preparation for Unified Kernel Image (UKI)                                                                                                |
| /boot                         | 1 GiB, fixed, ext4, also generous. After UKI, /boot can optionally be merged into the EFI partition                                                                            |
| host (root + home, Btrfs)     | ***single disk***: 25% of the disk, rounded up, snapped to a power-of-two step. Minimum 16 GiB, maximum 256 GiB. · ***multi disk***: 100% of the host disk (minus EFI + /boot) |
| data (persistent data, Btrfs) | ***single disk***: everything that remains · ***multi disk***: one Btrfs filesystem spanning every other eligible disk                                                         |

Btrfs relies on the kernel's `discard=async` default (6.2+) and the installed
system enables `fstrim.timer`, so freed space is returned to the virtual disk
automatically in thin-provisioned VMs. Hypervisor side: VMware thin disks and
Hyper-V dynamic VHDX reclaim on UNMAP natively; QEMU/KVM needs `discard=unmap`
on the drive (virt-manager exposes it per disk).

Worked examples:

| Disk    | host    | data    |
| ------- | ------- | ------- |
| 28 GiB  | 16 GiB  | 10 GiB  |
| 32 GiB  | 16 GiB  | 14 GiB  |
| 64 GiB  | 16 GiB  | 46 GiB  |
| 100 GiB | 32 GiB  | 66 GiB  |
| 512 GiB | 128 GiB | 382 GiB |
| 1 TiB   | 256 GiB | 766 GiB |

Every install gets host + data: the chosen disk hosts `host`, and every other eligible disk joins `data`. There is no other layout, no interactive partitioning, and no way to opt out. That is the point. (After installation the machine is yours: repartition, grow, shrink, do whatever you like. Birth is opinionated; life is yours.) The data is a plain multi-device Btrfs filesystem. It prioritizes capacity, not data redundancy. File data is not mirrored, so failure of any member disk can affect the filesystem.

**One filesystem, many devices.** On multi-disk machines the data is a single Btrfs filesystem spanning every non-host disk, and file managers (Dolphin's Devices panel) list each member separately (several identical `data` entries, one `host`, the EFI partition). Ignore those entries: everything lives in ONE place, the data mounted at `/data`. Add `/data` to your Places (favourites) and work from there.

---

## How it works

1. **Verify.** The pinned Fedora Everything ISO is checksummed.
2. **Flatten.** The Kickstart tree is resolved into a single file.
3. **Validate.** `ksvalidator` (F44 syntax) runs in the container.
4. **Bake.** `mkksiso` grafts the Kickstart and the offline repo onto the ISO and rewrites the boot arguments.
5. **Compose.** The embedded EFI system partition is rebuilt rootlessly (no loop devices needed) so UEFI boots see the Kickstart.
6. **Verify again.** Boot arguments in tree and ESP, repo repodata + comps, Kickstart presence, El Torito records, menu identity.

At install time the flow is: Anaconda starts → the KickBake pre-install script takes over a clean screen and lists eligible disks → you pick one and type `erase` → the script generates the storage plan at runtime → Anaconda performs the rest of the install unattended, entirely from the embedded repo.

---

## Design boundaries

KickBake owns machine birth: base OS, storage, boot. It deliberately does **not** own:

- Desktop preferences beyond stock Plasma
- Applications beyond the Plasma environment
- User accounts (first boot handles that)
- Security policy, shells, dotfiles, SSH keys. That is Ansible territory
- Anything requiring a network during install

---

## Repository layout

```
kickbake.py               the builder (stdlib Python)
config/kickbake.toml      build configuration
kickstart/
  kickbake.ks             base Kickstart (payload, boot, firstboot)
  select-disk.sh          the interactive disk-selection probe
podman/
  Containerfile           the Fedora build-toolchain image
  compose-offline.sh      rootless ESP rebuild + ISO composition
assets/                   pinned source ISO + checksum
tests/                    kickbake.py unit tests
```

---

## System footprint & cleanup

KickBake writes to exactly two places, both declared here. Nothing else
is touched: no root-owned files, no daemons, no SELinux relabeling of
your files, no services installed on the host, nothing in `/tmp` that
outlives a reboot.

**1. Inside the repository** (gitignored, disk-backed, reboot-proof):

| Path          | Contents                                                                                                                                                    | Remove with                                                                                                            |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `cache/repo/` | the offline repo + dnf download cache (~3.6 GB after refresh + prune: Packages/, repodata/, dnf-cache/, marker)                                             | `rm -rf cache/repo` (full reset) or `rm -rf cache/repo/dnf-cache` (keep the repo, reclaim the duplicate download copy) |
| `output/`     | build media: `*.iso`, `*.iso.sha256`, the flattened kickstart; a multi-GB `*.stage.iso` intermediate also exists *during* a build and is deleted on success | delete what you no longer need                                                                                         |

**2. The rootless Podman store** (`~/.local/share/containers/storage` per-user, no daemon, no root):

| Image                                  | Size         | Notes                                               |
| -------------------------------------- | ------------ | --------------------------------------------------- |
| `localhost/kickbake-builder:latest`    | ~408 MB      | the toolchain; rebuilt only when its recipe changes |
| `registry.fedoraproject.org/fedora:44` | ~190 MB      | the base image, shared with the toolchain's layers  |
| dangling `<none>` images               | ~400 MB each | left behind whenever the toolchain is rebuilt       |

Cleanup:

```bash
podman image prune                              # remove dangling images after rebuilds
podman rmi localhost/kickbake-builder:latest    # remove the toolchain
podman rmi registry.fedoraproject.org/fedora:44 # remove the base image
```

Removing the images is safe at any time: the next `kickbake.py doctor`
(or `repo`/`build`) rebuilds the toolchain from the Containerfile.

**Transient, self-cleaning:** running containers (`--rm`), Podman's run
scratch (`/run/user/1000/containers`), and the in-container dnf caches of
a repo build. And the one deliberate, permanent touch that is the
product itself: machines installed with the media carry Fedora, GRUB and
the host + data layout on the disks you confirmed with `erase`.

---

## AI assistance

KickBake was designed, directed, tested and maintained by the project author, with substantial assistance from AI tools during development. ChatGPT and GLM-5.3 Flash were used for code generation, debugging, review, documentation and technical discussion. All generated work was reviewed, tested and accepted by the maintainer, who takes responsibility for the resulting project.

## License

[MIT](LICENSE) © 2026 KickBake contributors. The installed media contains
Fedora, distributed under its own licenses.

---

## Status

KickBake is a personal project, actively used and tested on UEFI VMs and real NVMe hardware. If your mindset matches a browser-free, repeatable Fedora Plasma birth certificate for your machines, it may be exactly as useful to you as it is to me.
