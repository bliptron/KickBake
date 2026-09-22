# Changelog

All notable changes to KickBake are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

Changes on the road to 1.0.0, since `0.9.0-rc.1`.

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
