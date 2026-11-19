# Changelog

All notable changes to this project. Versions follow [Semantic Versioning](https://semver.org/);
releases are git tags (`vX.Y.Z`).

## [1.2.0] — unreleased

Profiles are now switched from the GNOME **Power Mode** menu through TLP 1.9
and `tlp-pd`. Nothing needs a reboot per switch.

### Added
- `battery-optimizer` CLI with `install`, `status`, `measure`, `uninstall` and
  `--dry-run`, installed to `/usr/local/sbin`.
- TLP 1.9 + `tlp-pd` from `ppa:linrunner/tlp`. Performance / Balanced /
  Power Saver map to TLP's `_ON_AC` / `_ON_BAT` / `_ON_SAV` values, generated
  from `config/profiles.conf` into `/etc/tlp.d/50-battery-optimizer.conf`.
- `battery-optimizer-hook.service`: a D-Bus listener with systemd hardening.
  In Power Saver it caps the internal panel brightness, stops Docker and caps
  the Intel iGPU frequency, then restores all three when you leave Power Saver.
  A udev rule resyncs it on AC plug/unplug.
- Hardware detection for the iGPU/dGPU (NVIDIA, AMD), the batteries and their
  charge-threshold support, the internal backlight, platform profiles, suspend
  modes and USB HID receivers. Nothing is hard-coded to the P14s.
- Charge thresholds (default 40 → 80 %) on every battery that supports them.
- An install manifest with checksums, and an `uninstall` that restores
  power-profiles-daemon/tuned, unit states, `prime-select` mode and the PPA.
- Migration of v1.0/v1.1 leftovers (modprobe files, `/etc/tlp.conf`, `.path`
  units, sysctl, legacy GRUB parameters), with backups.
- `status` warnings about VFIO/IOMMU boot parameters that weaken isolation.
- `measure [MIN]`: mean battery draw and estimated runtime (PRD §9).
- bats tests with sysfs fixtures for three laptop types, golden files and a
  manifest round-trip test. shellcheck + bats CI.
- `docs/GAMING.md`: per-game dGPU use with `tlpctl launch`.

### Changed
- No GPU-mode switching. NVIDIA stays on `prime-select on-demand` with runtime
  D3 (Turing+). `NVreg_TemporaryFilePath` moves from `/tmp` (tmpfs) to `/var/tmp`.
- Kernel parameters: none by default. TLP sets `NMI_WATCHDOG=0` and
  `MEM_SLEEP` at runtime, so `/etc/default/grub` is never edited (except to
  remove v1.x parameters during migration).
- Only drop-in files are written. `/etc/tlp.conf` is no longer overwritten.
- Profile files are parsed against an allow-list instead of being `source`d as root.
- Repository restructured: one copy of the code at the root; the version
  folders are replaced by tags `v1.0.0` and `v1.1.0`.

### Removed
- Forced `i915.enable_fbc` / `enable_psr`, `pcie_aspm=force`, obsolete i915
  options, `intel_idle.max_cstate`, `usbcore.autosuspend`,
  `nvme_core.default_ps_max_latency_us`, iwlwifi/iwlmvm module options and
  `powertop --auto-tune`.
- Gaming and Endurance profiles (see `docs/GAMING.md`).
- `vm.laptop_mode` sysctl (removed from the kernel in 7.0).

### Documented
- NVIDIA drivers (open and proprietary, any Ubuntu branch) and Lenovo firmware
  (fwupd/LVFS) are always supported as shipped: goal G7 and PRD §5.7, README
  "Driver and firmware updates".

### Fixed (found on the reference machine)
- The profile hook never started after a reboot: `WantedBy=multi-user.target`
  plus `After=tlp-pd.service` formed an ordering cycle (`tlp-pd` is
  `After=multi-user.target`). It now installs into `graphical.target`, and
  `install` uses `systemctl reenable` to drop the old link.
- `uninstall` restores the battery charge thresholds recorded at install (the
  firmware default 0-100 % when none were recorded). They live in the embedded
  controller, so removing TLP left the battery stuck at 40-80 %.
- `status` no longer exits when `/proc/driver/nvidia/gpus/*/power` is missing.
- `measure` skips 0 W samples (EC lag right after unplugging) instead of
  averaging them in.
- `status` shows the NVIDIA "Runtime D3 status" and warns when it is
  "Not supported".

## [1.1.0]

Four selectable profiles (Performance, Balanced, Endurance, Gaming); switch by
re-running the script and rebooting. Includes the interim safety fixes from
the v1.2 review (no forced FBC/PSR, no `pcie_aspm=force`, no `powertop --auto-tune`).

## [1.0.0]

Single profile, hard-coded for the ThinkPad P14s Gen 3.
