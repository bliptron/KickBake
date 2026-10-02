# Changelog

All notable changes to KickBake are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.2] - 2026-10-02

### Added

- Host-side NVRAM-hygiene test harness (`tests/nvram/`): fake
  `efibootmgr`/`lsblk`/`findmnt` exercise the real `%post` logic with no
  firmware, covering dangling, live and no-GPT entries.

### Changed

- **NVRAM hygiene now targets only dangling entries.** `%post` removes a
  firmware boot entry only when the GPT partition it points at no longer
  exists, and keeps every live entry -- including an OS on a disk KickBake did
  not touch. The freshly installed entry is placed first in the boot order; the
  other live entries are preserved. This replaces the previous pattern-match,
  which cleared every entry named `Fedora Linux` or `Windows Boot Manager`, so
  the documented "stale entries only" scope now matches the code.
- The toolchain image is rebuilt whenever `podman/Containerfile` changes: the
  build bakes a `kickbake.recipe` label carrying the recipe hash and
  `ensure_builder_image` compares it, matching the README's claim.
- README lists the hardcoded regional defaults (keyboard `gb`,
  `en_GB.UTF-8`, `Europe/London`) among "The opinions".
- `config/kickbake.toml`'s `repo_groups` now mirrors the kickstart `%packages`
  order (plus `core`), with the deliberate differences documented in both.

### Fixed

- `%post` writes `/etc/default/grub` and `/etc/dnf/dnf.conf` keys through an
  explicit `set_key` helper, so a key can never be duplicated (replaces the
  `grep && sed || echo` idiom, whose failure path could append a second line).
- `%post`'s `semanage fcontext` falls back to `-m` when the rule already exists
  instead of swallowing every error.
- `compose-offline.sh` drops the unused volume-id argument, and asserts the ESP
  size after `mkfs.vfat` so a future dosfstools change cannot silently
  truncate it.
- Host-side Python quotes the config-derived paths spliced into `bash -c`
  scripts, so a space or shell metacharacter in a value cannot break a command.
- `select-disk.sh`: fixed a comment typo; the launcher and UI `die()` now emit
  the same message and both mark the abort; the boot-medium list is
  de-duplicated; and `TEST && VAR` one-liners became `if` blocks (safe if
  `set -e` is ever added).
- Comment and doc corrections: `config/build.toml` -> `config/kickbake.toml`,
  `builder.py` -> `kickbake.py`, and internal `plans/...` references removed
  from shipped files.

## [1.0.1] - 2026-09-29

Minor bug fixes and internal cleanup; the installed system is unchanged.

### Changed

- Output naming drops the Fedora netinst revision:
  `fedora-plasma-44-kickbake-<YY.MM.DD>`. The Fedora release now comes from
  the config, so the source ISO may be renamed freely. The unused
  `menu_version` key is gone.

### Fixed

- Minor bug fixes: clearer failures when a path, a config file or podman is
  missing; `ksvalidator` output is no longer silently dropped; a failed
  build no longer leaves its multi-GB intermediate behind.

## [1.0.0] - 2026-09-23

The first stable release: every machine, born the same way.

### Added

- **NVRAM hygiene.** Repeated installs leave stale UEFI boot entries in
  the firmware, and wiped disks leave dangling `Windows Boot Manager`
  entries behind. `%post` now removes exactly those (pattern-matched),
  keeps the fresh entry, and sets it as the only boot choice. Fail-soft:
  an unwilling firmware never fails the install. `efibootmgr` joined the
  installed payload to make it possible.
- The `/boot` partition is labelled `boot`.
- Kernel retention: installed systems keep two kernels
  (`installonly_limit=2`).

### Fixed

- **USB flash drives could appear as install targets.** Modern sticks
  report `removable=0`, defeating the removable-flag check (that check
  was relaxed because NVMe devices lack the attribute). The eligibility
  filter is now layered: the disk serving the running installer is always
  excluded (even when a media-writing tool renamed its label), USB and
  MMC transports are excluded by kernel transport class, and the
  removable flag, the 24 GiB floor and the pseudo-device list remain.
  Internal NVMe/SATA/IDE/SCSI and VirtIO disks are unaffected.
- **`/data` was not writable by the admin user.** A fresh Btrfs subvolume
  root is always `root:root 0755`, and nothing set ownership after the
  mount — writes failed for every non-root user, and reformatting did not
  help (a recreated subvolume starts pristine again). `%post` now hands
  the subvolume to the first-boot admin (`chown 1000:1000`, mode `755`;
  no user exists at install time — Fedora's initial setup creates the
  admin with exactly that identity) and applies a real SELinux label to
  `/data` when the policy tooling is present, instead of leaving the
  `default_t` fallback.

### Changed

- **The persistent filesystem is now named `data`** (label and concept;
  previously `pool`). The subvolume, mountpoint and partition ids were
  already `data` — the label, documentation and layout prose now match,
  so one name covers the whole filesystem: label `data`, subvolume
  `data`, mounted at `/data`.
- The boot-menu layout readout gains a blank line before the first disk
  entry, for readability.
- Output naming: `kickbake-fedora-plasma-44.1.7-<date>` becomes
  `fedora-plasma-44.1.7-kickbake-<date>` -- the distro and desktop lead,
  the project brand marks the build date.
- The installed GRUB menu is hidden (2s timeout; hold `Shift` to reveal),
  per the owner's tested configuration.

## Planned for 1.1.0

- **`doctor` explains an end-of-life Fedora release.** When the configured
  release has left the live mirrors, `doctor` says so and points at the
  Fedora archive recovery path, instead of letting the next `repo`/`build`
  fail with a bare network error. Advisory only: it never changes doctor's
  exit code, and an already-built ISO is unaffected. Companion README note
  ("building after a release goes EOL").

## Planned for 2.0.0

- **Ansible handover.** A companion repository (`kickbake-configure`) that
  gives each newborn machine its personality — admin user, desktop
  preferences beyond stock Plasma, applications, security policy, shells,
  dotfiles, SSH keys. KickBake owns birth; Ansible owns everything after.
- **KickBake theme in the ISO.** A visual theme for the installed desktop,
  developed and soak-tested on a Fedora VM, bundled into the media so
  machines have the option to wear it.
- **Standalone refresh.** A dedicated operation (e.g.
  `python3 kickbake.py refresh`) that re-resolves the offline closure
  against the current Fedora release + updates and replaces `cache/repo`
  in place. Deliberately independent of both `build` — which never
  refreshes — and `repo`, which stays build-once and short-circuits on
  `cache/repo/.done`. Today the same effect requires deleting that marker
  by hand, as `repo` reports `[repo] already built` and exits.
- **Automatic ISO update in place of `pin-iso`.** `pin-iso` is replaced by
  a single update command that refreshes the pinned source ISO and keeps
  `[iso] source`, `expected_sha256` and `[fedora] release` in sync in one
  step, with a simplified argument set. Today pinning is manual: the ISO
  is passed by path, the official checksum via `--checksum`, and the
  Fedora release is edited by hand.

[Unreleased]: https://github.com/bliptron/KickBake/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/bliptron/KickBake/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/bliptron/KickBake/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/bliptron/KickBake/releases/tag/v1.0.0
