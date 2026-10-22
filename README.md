# Battery Optimizer

Battery tuning for **Ubuntu 24.04.5 LTS laptops with an integrated GPU plus a discrete GPU** (NVIDIA or AMD), switched with one click from the GNOME **Power Mode** menu.

Built on and tested against a **Lenovo ThinkPad P14s Gen 3** (i7-1280P, Iris Xe, NVIDIA T550, 52.5 Wh).

> **Status:** v1.1 is the current release. v1.2, described below and in [PRD.md](PRD.md), is in development. v1.2 changes how the project works; see [What changes from v1.1](#what-changes-from-v11).

## What this project is for

Hybrid-graphics laptops on Linux often drain fast because the discrete GPU stays powered, devices never enter low-power states, and the desktop's power modes only touch the CPU. Before v1.0, this P14s lasted about an hour unplugged and drew 21–23 W with the T550 fully active.

The project gets those laptops into a well-configured, low-power state and then stays out of the way:

- **One-click switching.** Performance, Balanced and Power Saver come from GNOME Quick Settings. No terminal and no reboot.
- **Battery longevity.** Charge thresholds (40 → 80 % by default) reduce wear on the cells.
- **A modest runtime gain.** Expect **up to about 1 extra hour at best**. On the P14s Gen 3 that's roughly **4 h → 5 h** of light use (browser, editor, terminal). Most of the large savings come from correct configuration of stock components, not from aggressive tweaks.
- **Stability first.** No forced or obsolete kernel and driver options. Everything can be undone.

## How it works (v1.2)

```
GNOME Quick Settings ──D-Bus──▶ tlp-pd ──▶ TLP applies the selected profile
   (Power Mode menu)                │        CPU, platform profile, PCIe/ASPM,
                                    │        USB, Wi-Fi, Intel GPU frequency
                                    ▼
                     battery-optimizer-hook ──▶ brightness cap, Docker stop/start
                     (listens for profile and AC changes)
```

### 1. GNOME's power menu drives TLP

TLP 1.9 ships `tlp-pd`, a replacement for `power-profiles-daemon` that speaks the same D-Bus API GNOME uses. Choosing a mode in Quick Settings switches the TLP profile directly:

| GNOME menu | What it does |
|---|---|
| **Performance** | Firmware performance profile, full turbo, devices awake. Default on AC |
| **Balanced** | Firmware balanced profile, moderate CPU cap, Wi-Fi power saving, runtime power management. Default on battery |
| **Power Saver** | Low-power firmware profile, turbo off, tight CPU and iGPU caps, deepest PCIe power saving, brightness capped, Docker paused |

You can also switch profiles from the terminal without sudo: `tlpctl`.

### 2. A small hook covers what TLP doesn't

`battery-optimizer-hook` watches for profile changes on D-Bus and for plug/unplug events through udev. It caps the internal panel's brightness and stops Docker in Power Saver, then restores both when you leave it.

### 3. One-time, install-only settings

These need a reboot, so they're set once at install and never per profile:

- **Discrete GPU powered off when idle.**
  - NVIDIA: proprietary driver with dynamic power management, `prime-select on-demand` permanently, and nouveau blacklisted.
  - AMD: runtime power management, which is on by default.
- **Charge thresholds** on laptops that support them.
- **A minimal kernel parameter set** in its own file (`/etc/default/grub.d/50-battery-optimizer.cfg`). `/etc/default/grub` is never edited.

### 4. Gaming without a gaming mode

The dGPU is used per application instead of switching the whole system. In Steam's launch options:

```
# NVIDIA
tlpctl launch -p performance prime-run %command%
# AMD
tlpctl launch -p performance env DRI_PRIME=1 %command%
```

### 5. Hardware detection

The installer detects the iGPU and dGPU vendors and drivers, the dGPU's PCI address, battery and charge-threshold support, the backlight device, platform-profile support and USB receivers. Nothing is hard-coded to the P14s.

### 6. Reversible by design

Only drop-in files are written: `/etc/tlp.d/`, `/etc/default/grub.d/`, `/etc/modprobe.d/`, `/etc/udev/rules.d/` and `/etc/systemd/system/`. Each one is recorded in a manifest. `uninstall` removes them and restores `power-profiles-daemon`. Every command supports `--dry-run`.

## Planned usage (v1.2)

```bash
git clone --branch v1.2.0 --depth 1 https://github.com/michaelkasede/battery-optimizer.git
cd battery-optimizer
sudo ./battery-optimizer install --dry-run   # preview
sudo ./battery-optimizer install
sudo reboot
# Then pick a mode in Quick Settings → Power Mode
sudo ./battery-optimizer status
sudo ./battery-optimizer measure 10          # average battery draw over 10 minutes
sudo ./battery-optimizer uninstall
```

Requirements: Ubuntu 24.04.5 LTS with GNOME, a laptop with a discrete GPU, and TLP ≥ 1.9 from `ppa:linrunner/tlp`. The installer adds the PPA.

## What changes from v1.1

| v1.1 | v1.2 |
|---|---|
| Re-run the script and reboot to change profile | Click in the GNOME power menu |
| Four profiles, including Gaming | Three GNOME modes; gaming uses per-game `prime-run` / `DRI_PRIME` |
| Switches `prime-select` between intel, on-demand and nvidia | Always on-demand; the dGPU powers itself off when idle |
| Edits `/etc/default/grub` and overwrites `/etc/tlp.conf` | Drop-in files only, tracked in a manifest |
| Forces i915 FBC/PSR, `pcie_aspm=force`, obsolete parameters | Driver defaults; TLP sets ASPM policy safely |
| Runs `powertop --auto-tune` alongside TLP | TLP is the only tool configuring power settings |
| Brightness and Docker watchers on `.path` units, which don't fire for `/sys` files | D-Bus and udev-triggered hook |
| Hard-coded for the P14s Gen 3 | Hardware detection for Ubuntu 24.04.5 dGPU laptops |

**Coming from v1.1?** v1.2's installer detects v1.1 leftovers and offers to remove them. Until then, `v1.1/restore-baseline.sh` removes the risky boot and driver settings, with backups:

```bash
sudo bash v1.1/restore-baseline.sh --dry-run
sudo bash v1.1/restore-baseline.sh && sudo reboot
```

## Versions

Releases are git tags. Check out the version you want to test:

```bash
git checkout v1.1.0      # four-profile script version
git checkout main        # latest
```

| Version | Summary |
|---|---|
| v1.0 | Single profile, hard-coded for the P14s Gen 3 |
| v1.1 | Four selectable profiles (Performance, Balanced, Endurance, Gaming); switch by re-running the script |
| v1.2 | GNOME power-menu integration via TLP 1.9 / tlp-pd, reversible drop-in configs, hardware detection *(in development)* |
| v2 "Powerplay" | Other distros and desktops *(planned)* |

The current tree still contains the `ubuntu+nvidia/` (v1.0) and `v1.1/` folders. v1.2 moves to a single root layout with tags, as described in [PRD.md §7](PRD.md#7-repository-and-versioning).

## Documentation

- [PRD.md](PRD.md) — requirements, design decisions, findings from the v1.1 review, test and measurement plan
- `v1.1/README.md` — v1.1 usage
- `v1.1/docs/STEAM-GAMING-GUIDE.md` — v1.1 gaming setup

## License and safety

Use at your own risk. This project changes system power, driver and boot configuration. Run with `--dry-run` first and review what it will change.
