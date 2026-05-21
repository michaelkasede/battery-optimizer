# Battery Optimizer v1.0

**Version:** 1.0 (frozen)  
**Target hardware:** Lenovo ThinkPad P14s Gen 3  
**GPU stack:** Ubuntu + NVIDIA (prime-select)

This is the original single-profile optimizer. It applies one fixed "balanced" configuration tuned for the author's laptop. No profile selection — run once, reboot, done.

For selectable profiles (Performance, Balanced, Endurance, Gaming), use **[v1.1](../v1.1/)** instead.

## Hardware This Was Built For

| Component | Spec |
|-----------|------|
| Laptop | Lenovo ThinkPad P14s Gen 3 |
| CPU | Intel Core i7-1280P (Alder Lake-P) |
| iGPU | Intel Iris Xe |
| dGPU | NVIDIA T550 |
| RAM | 48 GB DDR4-3200 |
| SSD | Samsung PM9A1 1TB NVMe |
| Battery | 52.5 Wh (Celxpert) |
| WiFi | Intel AX211 |

## Why It Exists

Battery sessions lasted ~1 hour at ~23 W drain. PowerTOP showed the NVIDIA T550 at 100% active even when idle. This script switches to on-demand hybrid graphics, configures TLP, i915, iwlwifi, GRUB, and systemd helpers to target ~3–4 hours of light dev work.

## Usage

```bash
sudo bash ubuntu-battery-optimizer.sh
sudo reboot
```

### Optional flags

```bash
sudo bash ubuntu-battery-optimizer.sh --disable-docker-on-battery
sudo bash ubuntu-battery-optimizer.sh --skip-docker-check
```

## What It Configures

- NVIDIA `prime-select on-demand` + fine-grained runtime PM
- TLP (CPU powersave on battery, 35% perf cap, ASPM, WiFi/BT/USB)
- Intel Iris Xe PSR2/FBC/RC6
- ThinkPad charge thresholds 40%–80%
- Display brightness cap (40%) on battery
- GRUB kernel parameters (deep sleep, NVMe PS, C-states)

## After Install

1. Reboot
2. BIOS (F1): Graphics Mode → **Integrated Only**
3. Run diagnostics: `bash battery-diagnostic.sh`
4. See [NVIDIA-GPU-BATTERY-GUIDE.md](NVIDIA-GPU-BATTERY-GUIDE.md) for troubleshooting

## Files

| File | Purpose |
|------|---------|
| `ubuntu-battery-optimizer.sh` | Main installer/configurator |
| `battery-diagnostic.sh` | Post-install power and GPU checks |
| `NVIDIA-GPU-BATTERY-GUIDE.md` | NVIDIA T550 and BIOS deep-dive |
| `powertop-*.txt` | Pre-optimization PowerTOP baseline |

## Log

`/var/log/battery-optimizer.log`
