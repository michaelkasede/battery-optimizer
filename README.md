# Battery Optimizer

Battery tuning for **Ubuntu 24.04.5 LTS laptops with an integrated GPU plus a discrete GPU** (NVIDIA or AMD), switched with one click from the GNOME **Power Mode** menu.

Built on and tested against a **Lenovo ThinkPad P14s Gen 3** (i7-1280P, Iris Xe, NVIDIA T550, 52.5 Wh).

> **Status:** v1.2.0 is implemented and pending the measurement gate in [PRD.md §4/§9](PRD.md#9-measurement-protocol). v1.1 is available as tag `v1.1.0`.

## What this project is for

Hybrid-graphics laptops on Linux often drain fast because the discrete GPU stays powered, devices never enter low-power states, and the desktop's power modes only touch the CPU. Before v1.0, this P14s lasted about an hour unplugged and drew 21–23 W with the T550 fully active.

The project gets those laptops into a well-configured, low-power state and then stays out of the way:

- **One-click switching.** Performance, Balanced and Power Saver come from GNOME Quick Settings. No terminal and no reboot.
- **Battery longevity.** Charge thresholds (40 → 80 % by default) reduce wear on the cells.
- **A modest runtime gain.** Expect **up to about 1 extra hour at best**. On the P14s Gen 3 that's roughly **4 h → 5 h** of light use (browser, editor, terminal). Most of the large savings come from correct configuration of stock components, not from aggressive tweaks.
- **Stability first.** No forced or obsolete kernel and driver options. Everything can be undone.

## Quick start

```bash
git clone --branch v1.2.0 --depth 1 https://github.com/michaelkasede/battery-optimizer.git
cd battery-optimizer
sudo ./battery-optimizer install --dry-run   # preview every change
sudo ./battery-optimizer install
sudo reboot                                  # only needed if install says so
```

Then pick a mode in **Quick Settings → Power Mode**, or from a terminal without sudo:

```bash
tlpctl power-saver      # or: tlpctl balanced | tlpctl performance
tlpctl get
```

Other commands:

```bash
battery-optimizer status                 # hardware, active profile, installed files, warnings
battery-optimizer measure 10             # mean battery draw over 10 min (unplugged)
sudo battery-optimizer uninstall --dry-run
sudo battery-optimizer uninstall         # back to stock Ubuntu power management
```

Install options: `--auto-switch 0|1|2` (TLP_AUTO_SWITCH, default 1), `--charge START:STOP` (default `40:80`), `--yes`, `--force`, `--no-migrate`. Uninstall options: `--keep-ppa`, `--yes`.

Requirements: Ubuntu 24.04.x with GNOME, a laptop with a discrete GPU and a battery, and the proprietary driver for NVIDIA (`sudo ubuntu-drivers install`). The installer adds `ppa:linrunner/tlp` for TLP ≥ 1.9 with `tlp-pd`.

## How it works

```
GNOME Quick Settings ──D-Bus──▶ tlp-pd ──▶ TLP applies the selected profile
   (Power Mode menu)                │        platform profile, CPU, PCIe ASPM,
   tlpctl                           │        USB, Wi-Fi, runtime PM, thresholds
                                    ▼
                     battery-optimizer-hook ──▶ Power Saver extras: brightness
                     (D-Bus + udev AC events)   cap, Docker stop, iGPU cap
```

### 1. GNOME's power menu drives TLP

TLP 1.9 ships `tlp-pd`, a replacement for `power-profiles-daemon` that implements the same D-Bus API GNOME uses. The menu switches TLP profiles directly:

| | Performance | Balanced | Power Saver |
|---|---|---|---|
| Firmware platform profile | performance | balanced | low-power |
| CPU turbo / max perf | on / 100 % | on / 80 % | off / 35 % |
| PCIe ASPM policy | default | powersupersave | powersupersave |
| Wi-Fi power saving | off | on | on |
| PCI runtime PM | on | auto | auto |
| Panel brightness cap (hook) | — | — | 40 % |
| Intel iGPU max freq (hook) | — | — | 30 % of range |
| Docker (hook) | — | — | stopped, restarted afterwards |
| Default when | on AC | on battery | chosen manually |

TLP 1.9 only has Power-Saver-specific (`_ON_SAV`) values for the CPU and platform profile. Every other device setting in Power Saver is the same as in Balanced. The hook adds the extras that set Power Saver apart.

All values live in [`config/profiles.conf`](config/profiles.conf). Edit them there and re-run `install`.

### 2. The hook covers what TLP doesn't

`battery-optimizer-hook.service` listens for `ActiveProfile` changes on D-Bus. A udev rule also asks it to resync on AC plug/unplug. Each change is recorded in `/var/lib/battery-optimizer/state.json`. It is restored once, and only if you haven't changed the value yourself in the meantime.

### 3. One-time, install-only settings

- **Discrete GPU off when idle.** NVIDIA uses the proprietary driver with `NVreg_DynamicPowerManagement=0x02` (Turing and newer), `prime-select on-demand` and nouveau blacklisted. Video memory is preserved across suspend in `/var/tmp`. AMD needs no options, since amdgpu runtime PM is on by default.
- **Charge thresholds** on every battery that exposes them. Batteries that only support a stop threshold get only that.
- **No kernel parameters.** TLP sets `NMI_WATCHDOG=0` and the suspend mode (`deep` only where `/sys/power/mem_sleep` offers it) at runtime. `/etc/default/grub` is not edited, except to remove v1.x parameters during migration.
- **One power manager.** `power-profiles-daemon` is replaced and `tuned` is disabled. `thermald` is enabled on Intel CPUs.

### 4. Gaming without a gaming mode

The dGPU is used per application. In Steam's launch options:

```
tlpctl launch -p performance prime-run %command%           # NVIDIA
tlpctl launch -p performance env DRI_PRIME=1 %command%     # AMD
```

See [docs/GAMING.md](docs/GAMING.md).

### 5. Hardware detection

The installer reads sysfs for the iGPU and dGPU (vendor, driver, PCI address, whether the dGPU has outputs), batteries and their charge thresholds, the internal panel's backlight, platform-profile choices, suspend modes and USB HID receivers (added to `USB_DENYLIST`). Unsupported setups are refused unless you pass `--force`.

### 6. Reversible by design

Only these files are written, each recorded with a checksum in `/etc/battery-optimizer/manifest`:

| File | Purpose |
|---|---|
| `/etc/tlp.d/50-battery-optimizer.conf` | Profile values |
| `/etc/battery-optimizer/hook.conf` | Hook settings |
| `/etc/systemd/system/battery-optimizer-hook.service` | Hook service |
| `/etc/udev/rules.d/80-battery-optimizer.rules` | AC events, NVIDIA runtime PM |
| `/etc/modprobe.d/50-battery-optimizer-nvidia.conf` | NVIDIA only |
| `/usr/local/sbin/battery-optimizer`, `/usr/local/lib/battery-optimizer/` | The tool itself |

`uninstall` removes them, puts back `power-profiles-daemon` (and `tuned`, if it was in use), restores the unit states and `prime-select` mode, and removes the PPA. Locally edited files are backed up before removal.

## Coming from v1.1

`install` detects v1.0/v1.1 leftovers, shows them, and removes them after you confirm (`--yes` skips the prompt). It backs everything up to `/etc/battery-optimizer/backup-*` first. The leftovers it looks for:

- `/etc/modprobe.d/{i915-power,iwlwifi-power,nvidia-power,blacklist-nouveau}.conf`
- `/etc/tlp.conf` written by v1.x
- `/etc/sysctl.d/99-battery-optimizer.conf`
- `/etc/udev/rules.d/80-nvidia-pm.rules`
- the `.path`/`.service` watchers
- the legacy GRUB parameters: `i915.enable_fbc/psr/rc6/gvt`, `pcie_aspm=force`, `intel_idle.max_cstate`, `usbcore.autosuspend` and `nvme_core.default_ps_max_latency_us`

VFIO/IOMMU parameters are left alone. `status` warns about the ones that weaken isolation.

## Measuring

Follow [PRD.md §9](PRD.md#9-measurement-protocol): unplug, set brightness to 40 %, use a steady workload, and wait 5 minutes. Then:

```bash
battery-optimizer measure 10
```

It prints the mean draw in watts and the runtime at that draw.

## Development

```bash
shellcheck battery-optimizer tests/stubs/stub   # follows sourced lib/*.sh
bats tests/                                     # needs bats-core and python3
```

The tests run the real CLI against fixture sysfs trees (P14s Gen 3, an AMD + AMD laptop, and an NVIDIA-with-outputs laptop) and a fake root. Stubbed `apt-get`/`systemctl`/… record every call. The suite includes golden files for every generated config and an install → uninstall round-trip that must leave the fake root byte-identical. Regenerate golden files with `UPDATE_GOLDEN=1 bats tests/render.bats`.

Layout:

```
battery-optimizer      CLI entry point
lib/                   common, config (allow-list parser), detect, render, manifest, migrate, system
config/profiles.conf   profile values
templates/             systemd unit, udev rules, modprobe drop-in
hook/profile-hook      D-Bus listener (python3-gi)
tests/                 bats tests, stubs, golden files
docs/GAMING.md
```

## Versions

Releases are git tags:

```bash
git checkout v1.1.0      # four-profile script version (reboot to switch)
git checkout v1.0.0      # original single-profile script
```

| Version | Summary |
|---|---|
| v1.0 | Single profile, hard-coded for the P14s Gen 3 |
| v1.1 | Four selectable profiles; switch by re-running the script |
| v1.2 | GNOME power-menu integration via TLP 1.9 / tlp-pd, reversible drop-in configs, hardware detection |
| v2 "Powerplay" | Other distros and desktops *(planned)* |

See [CHANGELOG.md](CHANGELOG.md) and [PRD.md](PRD.md).

## License and safety

Use at your own risk. This project changes system power, driver and boot configuration. Run with `--dry-run` first and review what it will change.
