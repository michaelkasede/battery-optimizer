# PRD — Battery Optimizer v1.2

| | |
|---|---|
| **Owner** | Michael Kasede |
| **Status** | Implemented on `feature/tlp-pd`; measurement gate (§4, §9) pending on the reference machine |
| **Target release** | v1.2.0 |
| **Reference hardware** | Lenovo ThinkPad P14s Gen 3 (21AL) — i7-1280P, Iris Xe, NVIDIA T550 (no display outputs), 52.5 Wh |
| **Supported platform** | Ubuntu 24.04.5 LTS (GNOME 46, Wayland or X11) on laptops with an integrated GPU + a discrete GPU |
| **Last updated** | 2026-10-22 |

---

## 1. Summary

v1.2 replaces the script-driven, reboot-to-switch profile system of v1.1 with **TLP 1.9 + `tlp-pd`**, so power profiles are switched with **one click in the GNOME Quick Settings "Power Mode" menu** (Performance / Balanced / Power Saver). Everything that needs a reboot (driver options, GPU mode, kernel parameters) becomes a one-time install step, kept to the minimum that is known to be safe. The installer becomes idempotent, fully reversible, and hardware-detecting so it works on any Ubuntu 24.04.5 laptop with a discrete GPU, not just the P14s.

## 2. Goals and expected benefit

The realistic benefit of this project is **battery longevity** and **up to ~1 extra hour of runtime at best** — on the P14s Gen 3, roughly **4 h → 5 h** of light use (browser, editor, terminal). It is not a multiplier; most of the large wins (dGPU powered off at idle, CPU energy policy, firmware platform profile) are already achievable with stock components when they are configured correctly.

| # | Goal | Measure of success |
|---|------|--------------------|
| G1 | One-click profile switching from the GNOME power menu | Selecting a mode in Quick Settings applies all runtime settings within ~2 s, no terminal, no reboot |
| G2 | Battery runtime | Idle/light-use draw on battery ≤ v1.1 Balanced; target ≈ +1 h over stock Ubuntu on the P14s (≈ 4 h → 5 h), measured with the protocol in §9 |
| G3 | Battery longevity | Charge thresholds (default 40 → 80 %) applied on every boot where the hardware supports them |
| G4 | Stability | No forced/obsolete kernel or driver parameters by default; zero display flicker, Wi-Fi, NVMe or USB regressions attributable to the project |
| G5 | Reversibility | `--uninstall` returns the machine to stock Ubuntu config; every file written is tracked in a manifest |
| G6 | Portability | Works on Ubuntu 24.04.5 laptops with NVIDIA or AMD dGPUs via hardware detection; no hard-coded PCI addresses or USB IDs |

### Non-goals

- Distros other than Ubuntu 24.04.5 LTS (that is v2 "Powerplay").
- Overclocking, undervolting, fan curves, or anything that can damage hardware.
- Replacing the desktop's power UI with a custom GNOME Shell extension.
- Guaranteeing a specific runtime — results depend on battery health, panel, and workload.

## 3. Background — what we found in v1.1

Investigation started from an external HDMI monitor that intermittently blanked. A cable swap appears to have resolved the blanking, but the review of v1.1 found several settings that are risky, obsolete, or fighting each other:

### 3.1 Risky or no-op settings currently applied

| Setting | Where | Problem | v1.2 action |
|---|---|---|---|
| `i915.enable_fbc=1` | GRUB + modprobe.d | Forced framebuffer compression is a known cause of flicker/corruption on Intel graphics | Remove — use driver default |
| `i915.enable_psr=2` | GRUB + modprobe.d | Forcing PSR2; driver already enables PSR when the panel supports it | Remove — use driver default |
| `pcie_aspm=force` | GRUB | Enables ASPM on devices whose firmware says it is unsupported; can cause intermittent device faults | Remove — TLP sets ASPM *policy* safely |
| `i915.enable_rc6=7`, `i915 lvds_downclock=1` | GRUB + modprobe.d | Parameters removed from the kernel years ago — ignored | Remove |
| `i915.enable_gvt=1` | GRUB (not from this script) | GVT-g is not supported on 12th-gen Intel | Remove |
| `intel_idle.max_cstate=9` | GRUB | Higher than the number of C-states on the CPU — no effect | Remove |
| `usbcore.autosuspend=5` | GRUB | Duplicates TLP's USB autosuspend globally, bypasses TLP's denylist | Remove |
| `nvme_core.default_ps_max_latency_us=5500` | GRUB | Caps NVMe APST below default — undercuts power saving; only a workaround for buggy drives | Remove unless a drive needs it |
| `options iwlmvm power_scheme=3`, `iwlwifi power_save=1` | modprobe.d | Duplicates TLP `WIFI_PWR_*`; low-power scheme can hurt latency | Remove — TLP owns Wi-Fi power |
| `powertop --auto-tune` | installer step 7 | Enables runtime PM / autosuspend on *everything*, overriding TLP's NVIDIA and USB denylists | Remove |
| USB denylist missing Logi Bolt (`046d:c548`) | tlp.conf | Receiver autosuspends → mouse/keyboard lag | Detect receivers automatically |

### 3.2 Bugs in v1.1

1. **GRUB merge is add-only.** If a key already exists, its value is never updated or removed, so switching profiles never changes kernel parameters (Gaming still boots with `fbc=1` and `aspm=force` after a Balanced run).
2. **`.path` units never fire.** `PathChanged=` relies on inotify, which does not generate events for sysfs attributes, so the brightness cap and Docker auto-stop most likely never trigger.
3. **`/etc/tlp.conf` is overwritten** with no backup, discarding package defaults and user edits.
4. **Profiles are `source`d as root.** Any code in `profiles/*.env` runs as root.
5. **Version folders** (`ubuntu+nvidia/`, `v1.1/`) duplicate code that git already versions.

### 3.3 Out-of-scope boot parameters found on the reference machine

`intel_iommu=on iommu=pt vfio_iommu_type1.allow_unsafe_interrupts=1 kvm.ignore_msrs=1 pcie_acs_override=downstream,multifunction` — leftovers from a VFIO/GPU-passthrough setup, not written by this project. `pcie_acs_override` is a no-op on Ubuntu's stock kernel; `allow_unsafe_interrupts` weakens IOMMU isolation. v1.2 must **not** touch these, but `--status` should warn about them.

### 3.4 Interim fixes already in the working tree (uncommitted)

- `v1.1/restore-baseline.sh` — removes the §3.1 GRUB/modprobe settings with backups, `--dry-run`, and an undo command.
- `v1.1/profiles/*.env` — `I915_ENABLE_FBC=-1`, `I915_ENABLE_PSR=-1`, `GRUB_PCIE_ASPM=default`.
- `v1.1/ubuntu-battery-optimizer.sh` — dropped obsolete i915 options, redundant GRUB params, and `powertop --auto-tune`.

These should be committed (or folded into the v1.2 branch) before the restructure.

## 4. Decision — TLP 1.9 + `tlp-pd`

TLP 1.9.0 ships **`tlp-pd`**, a drop-in replacement for `power-profiles-daemon` that implements the same D-Bus API GNOME uses. The GNOME Power Mode menu therefore switches TLP profiles directly:

| GNOME menu | TLP profile | TLP parameter suffix |
|---|---|---|
| Performance | performance | `*_ON_AC` |
| Balanced | balanced | `*_ON_BAT` |
| Power Saver | power-saver | `*_ON_SAV` |
| — | all profiles | no suffix |

`TLP_AUTO_SWITCH` controls automatic switching: `0` never (uses `TLP_DEFAULT_MODE`), `1` Performance on AC / Balanced on battery, `2` keep the manually selected profile. `tlpctl` switches/queries profiles without sudo and can launch a program under a profile (`tlpctl launch -p performance <cmd>`).

### Alternatives considered

| Option | Verdict |
|---|---|
| **A. TLP 1.9 + tlp-pd (chosen)** | Native GNOME toggle, keeps TLP's device-level savings (USB, PCIe runtime PM, ASPM policy, Wi-Fi, charge thresholds), almost no custom code |
| B. Keep power-profiles-daemon, drop TLP, add a D-Bus listener running our scripts | Simplest stack; loses most device-level savings; we own the glue. Fallback if A misbehaves |
| C. Custom GNOME Shell extension with four modes | Most flexible (Gaming in the menu) but tied to GNOME versions and needs a polkit-backed root helper |
| D. Keep v1.1 reboot-to-switch | Rejected — no UI, reboot per switch, conflicting tools |

**Gate:** before release, measure stock Ubuntu (power-profiles-daemon, Power Saver) vs. v1.2 Power Saver (§9). If the difference is < 0.5 W at idle, document that and consider Option B as the lighter default.

## 5. Requirements

### 5.1 Profiles (runtime — switch instantly from the GNOME menu)

All three profiles are expressed as TLP parameters in a single drop-in, `/etc/tlp.d/50-battery-optimizer.conf`:

| Area | Performance (`_AC`) | Balanced (`_BAT`) | Power Saver (`_SAV`) |
|---|---|---|---|
| `PLATFORM_PROFILE` | performance | balanced | low-power |
| `CPU_ENERGY_PERF_POLICY` (only used if no platform profile) | balance_performance | balance_power | power |
| `CPU_BOOST` / `CPU_HWP_DYN_BOOST` | 1 / 1 | 1 / 0 | 0 / 0 |
| `CPU_MAX_PERF` | 100 | 60–80 | 35 |
| Intel GPU max/boost freq | default | default | capped (detect min/max from sysfs) |
| `PCIE_ASPM` | default | powersupersave ¹ | powersupersave ¹ |
| `WIFI_PWR` | off | on ¹ | on ¹ |
| `RUNTIME_PM` | on ² | auto ¹ | auto ¹ |
| Intel iGPU max/boost freq (hook) | default | default | 30 % of RPn→RP0 range ³ |
| Brightness cap (hook) | off | off | 40 % |
| Docker (hook) | ignore | ignore | stop while active, restore on exit |

¹ **TLP 1.9 has `_ON_SAV` variants only for `CPU_*`, `PLATFORM_PROFILE` and `AMDGPU_ABM_LEVEL`** (verified in the 1.9.1 source: `tlp.conf.in`, `func.d/*` map power-saver to the `_ON_BAT` value for every other parameter). Balanced and Power Saver therefore always share ASPM, Wi-Fi, runtime PM, SATA, audio and Intel GPU frequency settings. `PCIE_ASPM_ON_BAT=powersupersave` is a *policy* that only uses link states the firmware allows. It is not `pcie_aspm=force`.
² dGPU drivers (`nvidia`, `amdgpu`, `nouveau`, `radeon`) are added to `RUNTIME_PM_DRIVER_DENYLIST`, so `RUNTIME_PM_ON_AC=on` can't keep the dGPU awake on AC. The GPU driver decides alone.
³ Power-Saver-only extras that TLP can't express are applied by the hook (§5.2). The iGPU cap is i915-only. On `xe` it is skipped.

Exact values are tuning decisions to validate with measurements. They live in one place (`config/profiles.conf`) and are rendered into the drop-in.

Default: `TLP_AUTO_SWITCH=1` (Performance on AC, Balanced on battery, Power Saver when chosen), set with `install --auto-switch`. TLP's own semantics: `0` = never switch (`TLP_DEFAULT_MODE`), `1` = always switch on plug/unplug and boot, `2` = *smart* (TLP's default). Smart mode keeps a Power Saver/Balanced choice on AC, and a Power Saver/Performance choice on battery, across plug events.

### 5.2 Profile hook (brightness cap, Docker)

TLP has no documented hook for profile changes, so v1.2 adds a small root service, `battery-optimizer-hook.service`:

- Subscribes to `PropertiesChanged` for `ActiveProfile` on `org.freedesktop.UPower.PowerProfiles` (system bus) using `gdbus monitor` or a short Python (`python3-gi`) script — no polling.
- Also reacts to AC plug/unplug via a **udev rule** on `SUBSYSTEM=="power_supply"` (replaces the broken `.path` units).
- Actions are idempotent and state-tracked in `/var/lib/battery-optimizer/` (saved brightness, "docker was running" flag).
- Brightness is applied through the backlight sysfs device of the **internal panel only**.

### 5.3 Install-time settings (reboot once, never per profile)

| Component | Requirement |
|---|---|
| **TLP** | Install TLP ≥ 1.9 with `tlp-pd` and `tlp-rdw` from `ppa:linrunner/tlp`; remove `power-profiles-daemon` and `tuned-ppd` (the Debian `tlp-pd` package `Conflicts:` with both); disable + mask `tuned` if present (it was enabled on the reference machine) |
| **Charge thresholds** | `START_CHARGE_THRESH_BAT0` / `STOP_CHARGE_THRESH_BAT0` (default 40/80) in the TLP drop-in; skip with a notice where unsupported |
| **NVIDIA dGPU** | Proprietary driver (verified, not auto-installed: `ubuntu-drivers install` may need Secure Boot MOK enrollment); `NVreg_DynamicPowerManagement=0x02` (Turing and newer, detected as PCI device ID ≥ 0x1e00); `prime-select on-demand` permanently; nouveau blacklisted; enable `nvidia-suspend/resume/hibernate` services when `PreserveVideoMemoryAllocations=1`; temp file path on disk (`/var/tmp`), not tmpfs |
| **AMD dGPU** | No driver options needed (runtime PM is default); verify `power/control=auto`; document `DRI_PRIME=1` |
| **No GPU-mode switching** | Remove `prime-select intel/nvidia` from profiles — on-demand already powers the dGPU off when idle, and switching needs a logout/reboot |
| **Gaming** | Not a menu mode. Document Steam launch options: NVIDIA `tlpctl launch -p performance prime-run %command%`; AMD `tlpctl launch -p performance env DRI_PRIME=1 %command%` |
| **Kernel parameters** | **None.** TLP already sets `NMI_WATCHDOG=0` by default and `MEM_SLEEP_ON_AC/BAT` at runtime (rendered as `deep` only if `/sys/power/mem_sleep` lists it), so no `/etc/default/grub.d/` file is needed. `/etc/default/grub` is only edited by the v1.x migration, with a backup |
| **thermald** | Enable on Intel CPUs only |
| **Driver options** | None for i915/xe or iwlwifi by default |

### 5.4 Hardware detection

Detect at install and on `--status`; never hard-code:

- iGPU vendor/driver (i915, xe, amdgpu) and dGPU vendor/driver/PCI address (`lspci -D -nn`, class 0300/0302).
- Whether the dGPU drives any outputs (VGA vs 3D controller) — informational, used in diagnostics.
- Battery name(s) (`BAT0`, `BAT1`) and charge-threshold support.
- Backlight device for the internal panel.
- Platform profile support (`/sys/firmware/acpi/platform_profile_choices`).
- USB HID receivers (Logitech Unifying/Bolt and similar) → `USB_DENYLIST`. Note: TLP already skips autosuspend for any USB device with a HID interface (`_hid_deny` in `func.d/20-tlp-func-usb`). The v1.1 receiver lag was most likely caused by `usbcore.autosuspend=5` / `powertop --auto-tune`, which bypass TLP. The explicit denylist is kept as a safeguard.
- Suspend modes available.
- Unsupported configurations (not Ubuntu 24.04.x, no dGPU, no battery) → refuse with a clear message unless `--force`.

### 5.5 CLI

Single entry point, e.g. `battery-optimizer` (installed to `/usr/local/sbin`):

```
battery-optimizer install [--auto-switch 0|1|2] [--charge 40:80] [--dry-run]
battery-optimizer status          # detected hardware, active profile, applied files, warnings
battery-optimizer measure [MIN]   # average battery draw over N minutes
battery-optimizer uninstall [--dry-run]
battery-optimizer --version
```

Profile switching is done in the GNOME menu or `tlpctl`, not by this CLI.

### 5.6 Reversibility

- Every file written is recorded in `/etc/battery-optimizer/manifest` with a checksum.
- Only drop-in files are created (`/etc/tlp.d/`, `/etc/default/grub.d/`, `/etc/modprobe.d/`, `/etc/udev/rules.d/`, `/etc/systemd/system/`); no existing system file is edited in place.
- `uninstall` removes manifest files, reinstalls `power-profiles-daemon`, optionally removes the TLP PPA, rebuilds initramfs/GRUB only if a boot-time file was removed.
- `--dry-run` prints every action without changing anything.
- Migration: `install` detects v1.1 artifacts (`/etc/modprobe.d/i915-power.conf`, `iwlwifi-power.conf`, `/etc/tlp.conf` written by v1.1, legacy GRUB params, `.path` units) and offers to remove them, folding in `restore-baseline.sh`.

## 6. Security requirements

The tool runs as root; treat it as privileged code.

- Profile/config files are parsed as `KEY=VALUE` against an allow-list of keys and value patterns — never `source`d.
- Installed scripts and config are `root:root`, mode `0644`/`0755`; refuse to run if repo config files are world-writable.
- The hook service runs with systemd hardening where possible (`ProtectSystem`, `ProtectHome`, `NoNewPrivileges`, narrow `ReadWritePaths`).
- No network access after package install; the PPA is the only added source and is listed in `status` and removed by `uninstall`.
- `status` warns (does not change) about weakening boot parameters such as `vfio_iommu_type1.allow_unsafe_interrupts`.
- `set -euo pipefail` everywhere; quote all expansions; shellcheck-clean.

## 7. Repository and versioning

Move from version folders to standard git versioning:

- **One copy of the code at the repo root.** `main` = latest stable.
- **Semantic version tags** for releases: `v1.0.0`, `v1.1.0`, `v1.2.0`. Testers use `git clone --branch v1.2.0 --depth 1 …` or `git checkout v1.1.0`.
- **Feature branches** for work (`feature/tlp-pd`, `fix/udev-power-events`), merged via PR, then tagged. Long-lived `release/1.x` branches only if 1.x needs patches after v2 starts.
- **GitHub Releases** with notes from `CHANGELOG.md`; single-source version in a `VERSION` file.

Proposed layout:

```
battery-optimizer/
├── README.md
├── PRD.md
├── CHANGELOG.md
├── VERSION
├── battery-optimizer            # CLI entry point
├── lib/                         # detect.sh, render.sh, manifest.sh, ...
├── config/
│   └── profiles.conf            # Performance / Balanced / Power Saver values
├── templates/                   # tlp drop-in, grub.d cfg, modprobe, udev, systemd units
├── hook/
│   └── profile-hook             # D-Bus listener for brightness / Docker
├── tests/                       # bats tests + fixtures (sample grub, tlp.conf, lspci output)
├── docs/
│   └── GAMING.md
└── .github/workflows/ci.yml     # shellcheck + bats
```

Migration steps:

1. Commit the interim fixes (§3.4).
2. Optionally reconstruct v1.0 from `ubuntu+nvidia/` as a commit and tag `v1.0.0`; tag current v1.1 `v1.1.0`.
3. On `feature/tlp-pd`: `git mv` v1.1 content to the root layout, delete the version folders, implement v1.2.
4. Merge, tag `v1.2.0`, publish a GitHub Release.

## 8. Testing

- **Static:** shellcheck in CI on every push/PR.
- **Unit (bats):** renderers produce the expected TLP/GRUB/modprobe files from fixtures; v1.1 migration removes exactly the listed parameters (fixture: the reference machine's current cmdline); manifest/uninstall round-trip leaves fixtures identical.
- **Detection fixtures:** captured `lspci`, `lsusb`, sysfs trees for the P14s Gen 3 plus at least one AMD-dGPU and one NVIDIA-with-outputs laptop.
- **Manual matrix (reference machine):** install → reboot → switch each GNOME mode → verify with `tlp-stat -s -p`, `tlpctl`, `cat /proc/cmdline`; AC plug/unplug triggers hook; external HDMI and USB-C monitors stable for ≥ 1 h; suspend/resume with dGPU idle; Steam game with `prime-run`; uninstall → reboot → stock behaviour restored.

## 9. Measurement protocol

Used for the §4 gate and to substantiate the runtime claim.

1. Battery 60–90 %, unplugged, brightness fixed at 40 %, Wi-Fi on, same apps open (browser with 3 tabs, editor, terminal), external display disconnected.
2. Wait 5 min after unplugging for settling.
3. Sample `/sys/class/power_supply/BAT0/power_now` every 10 s for 10 min; report the mean in watts (`battery-optimizer measure 10`).
4. Run for: stock Ubuntu (power-profiles-daemon) Balanced and Power Saver; v1.2 Balanced and Power Saver.
5. Estimated runtime = usable Wh ÷ mean W. On 52.5 Wh, ~1 W less at a 7–8 W idle ≈ +1 h.

## 10. Milestones

| Release | Scope |
|---|---|
| **v1.2.0** | Repo restructure + tags; TLP 1.9 / tlp-pd GNOME integration; drop-in configs; udev/D-Bus hook; v1.1 migration; remove GPU-mode switching; `install/status/uninstall/--dry-run`; measurements published |
| **v1.3.0** | Hardening (§6) complete; bats + CI; detection for AMD dGPU and NVIDIA-with-outputs laptops; `measure` command |
| **v2.0 "Powerplay"** | Other distros and package managers; non-Ubuntu desktops |

## 11. Decisions on the former open questions

| # | Question | Decision |
|---|---|---|
| 1 | `TLP_AUTO_SWITCH` default | `1`: predictable (Performance on AC, Balanced on battery). `--auto-switch 2` gives TLP's smart mode |
| 2 | Balanced CPU cap | `CPU_MAX_PERF_ON_BAT=80` with turbo on. The aggressive 35 % cap moved to Power Saver |
| 3 | Docker in Power Saver | Stop automatically (`HOOK_DOCKER=stop`), restart on leaving. Only if `docker.service` was running; `warn` and `ignore` are available |
| 4 | README BIOS checklist | Dropped from docs until verified on the P14s Gen 3 BIOS. No step depends on it |
| 5 | `mem_sleep_default=deep` | Not a kernel parameter any more. TLP `MEM_SLEEP_*=deep` only where the firmware lists `deep` |
| 6 | VFIO/IOMMU parameters | Left to the user. `status` warns (allow_unsafe_interrupts, pcie_acs_override, kvm.ignore_msrs, iommu=pt, intel_iommu=on). No opt-in cleanup in v1.2 |

## 12. Implementation notes and refinements (v1.2.0)

Findings while implementing that change or sharpen the requirements above:

1. **Power Saver fallback (§5.1 ¹).** Only CPU/platform-profile settings differ between Balanced and Power Saver in TLP 1.9. Everything else Power Saver does differently comes from the hook (brightness, iGPU cap, Docker).
2. **No boot parameters needed (§5.3).** TLP covers the NMI watchdog and suspend mode at runtime. A clean v1.2 install leaves `/proc/cmdline` stock, apart from the user's own VFIO parameters.
3. **Dead v1.1 settings on current kernels.** `vm.laptop_mode` and TLP `DISK_IDLE_SECS_*` have no effect on kernel ≥ 7.0 (laptop_mode was removed; the reference machine runs 7.0). They are not carried over.
4. **Profile-change signal.** TLP calls back into `tlp-pd` after it applies a profile, including automatic switches on plug/unplug, so `PropertiesChanged(ActiveProfile)` covers both manual and automatic changes. The udev rule only triggers a debounced resync (`systemctl try-reload-or-restart` → SIGHUP), which keeps the hook correct if `tlp-pd` restarts or misses an event.
5. **Hook state is "restore once, only if untouched".** A value the user changed while in Power Saver (e.g. brightness) is not overwritten when they leave it. State lives in `/var/lib/battery-optimizer/state.json` (`StateDirectory=`), so it survives reboots.
6. **Hook hardening.** `ProtectSystem=strict` (with `/sys` writable), `ProtectHome`, `PrivateTmp`, `PrivateNetwork`, `NoNewPrivileges`, `RestrictAddressFamilies=AF_UNIX`, `UMask=0077` and kernel/cgroup/clock protections. Docker is controlled through the systemd D-Bus API, never a shell.
7. **Detection details.** The iGPU is the GPU with an eDP/LVDS/DSI connector, falling back to `boot_vga` and then to Intel. This handles AMD APUs that are not on PCI bus 0. HID batteries (`scope=Device`) are ignored. A missing platform-profile choice is mapped to the closest one (`low-power` → `quiet` / `cool`). With no platform profile at all, `PLATFORM_PROFILE_*` is omitted and TLP falls back to EPP.
8. **Reference machine observations (2026-10-22).** v1.1 leftovers are still active (forced FBC/PSR, `pcie_aspm=force` and the rest of §3.1 in `/proc/cmdline`). `power-profiles-daemon` and `tuned` are both enabled while TLP is not installed. The T550 showed `runtime_status=active` on battery at ~18 W. `status` now reports the dGPU wake state and `nvidia-persistenced`, so this can be checked again after migration and a reboot.
9. **Versioning (§7).** Tags `v1.0.0` (commit 73ebd71, the original root-level script) and `v1.1.0` (v1.1 + interim fixes) exist. The version folders were removed on `feature/tlp-pd`.
10. **Verification done without root.** shellcheck clean. 57 bats tests cover the parser, detection on three fixture laptops, golden renders, migration, the install/idempotence/uninstall round-trip, and the hook logic. The hook was also tested live over D-Bus against the reference machine's `org.freedesktop.UPower.PowerProfiles` API (the one `tlp-pd` implements), including a real profile switch. `systemd-analyze verify` and `udevadm verify` pass for the generated unit and rules. **Still to do on hardware:** the §8 manual matrix and the §9 measurements.
