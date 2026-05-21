# Battery Optimizer v1.1

**Version:** 1.1.0  
**Target hardware:** Lenovo ThinkPad P14s Gen 3 (same as v1.0)  
**New in v1.1:** Four selectable power profiles + Steam gaming guide

## Quick Start

```bash
sudo bash ubuntu-battery-optimizer.sh
# Interactive menu appears — press Enter for Balanced (default)
sudo reboot
```

Non-interactive:

```bash
sudo bash ubuntu-battery-optimizer.sh --mode balanced
sudo bash ubuntu-battery-optimizer.sh --mode endurance
sudo bash ubuntu-battery-optimizer.sh --mode gaming
```

## Power Profiles

When you run the script, you choose a profile. **Balanced is the default** — press Enter to accept it.

```
  [1] Performance  — max responsiveness on battery (~1.5–2h)
  [2] Balanced     — daily dev work (~3–4h)          [default]
  [3] Endurance    — maximum battery runtime (~4–5h+)
  [4] Gaming       — Steam / dGPU games (AC required)
  Choice [2]:
```

### Profile comparison

| Setting | Performance | Balanced | Endurance | Gaming |
|---------|-------------|----------|-----------|--------|
| `prime-select` | on-demand | on-demand | **intel** | **nvidia** |
| CPU max on battery | 80% | 35% | 20% | 40% |
| Turbo on battery | On | Off | Off | Off |
| Brightness cap | Off | 40% | 30% | Off |
| Docker on battery | Warn | Warn | **Auto-stop** | Ignore |
| Charge thresholds | 20–100% | 40–80% | 40–80% | 20–100% |
| Est. battery (light dev) | ~1.5–2 h | ~3–4 h | ~4–5+ h | **Plug in AC** |

### When to use each profile

- **Balanced** — Default for Cursor, Chrome, terminal work. Same target as v1.0.
- **Performance** — Local builds, compilation, or GPU offload via `prime-run` when you need speed on battery and accept shorter runtime.
- **Endurance** — Flights, meetings, writing. Disables dGPU entirely (`intel` mode). Re-run with another profile before using CUDA or `prime-run`.
- **Gaming** — Sets `prime-select nvidia`, max CPU on AC, disables power-saving that hurts frame rates. **Always plug in the power adapter.** See [docs/STEAM-GAMING-GUIDE.md](docs/STEAM-GAMING-GUIDE.md).

## Command-Line Options

```bash
sudo bash ubuntu-battery-optimizer.sh [OPTIONS]

  --mode MODE               performance | balanced | endurance | gaming
  --skip-docker-check         Skip Docker warning during install
  --disable-docker-on-battery Legacy flag; Endurance profile stops Docker by default
  -h, --help                  Show help
```

## Switching Profiles

Re-run the script with a different `--mode`. Each run overwrites TLP, GPU mode, and systemd helpers for the new profile. Reboot after switching, especially when changing GPU mode (`intel` ↔ `nvidia`).

Active profile is stored at `/etc/battery-optimizer/mode`.

## Verification

```bash
bash battery-diagnostic.sh
cat /etc/battery-optimizer/mode
prime-select query
watch -n 1 cat /sys/class/power_supply/BAT0/power_now   # on battery
```

Expected idle draw on battery (after reboot + BIOS Integrated):

| Profile | Target idle |
|---------|-------------|
| Balanced | 6–10 W |
| Endurance | 5–7 W |
| Performance | 10–14 W |
| Gaming (on AC) | 15–40 W under load (normal) |

## BIOS Checklist (all profiles except Gaming)

Press **F1** at boot:

- Config → Power → Graphics Mode = **Integrated Only**
- Enable Panel Self-Refresh (PSR)
- Sleep State = **Linux S3**
- Disable Wake on LAN, USB Wake, Always On USB

For **Gaming**, set BIOS Graphics Mode to **Hybrid** or **Discrete** so the T550 is available.

## Files

| Path | Purpose |
|------|---------|
| `ubuntu-battery-optimizer.sh` | Main script (v1.1.0) |
| `battery-diagnostic.sh` | Diagnostics + active profile display |
| `profiles/*.env` | Profile parameter definitions |
| `docs/STEAM-GAMING-GUIDE.md` | Steam, Proton, and AC-power setup |

## How Profiles Affect Linux

Each profile tunes the full power stack:

1. **CPU** — `intel_pstate` governor, perf caps, turbo boost via TLP
2. **Platform** — `/sys/firmware/acpi/platform_profile` (low-power / performance)
3. **GPU** — `prime-select` mode + `NVreg_DynamicPowerManagement`
4. **Display** — i915 PSR/FBC; optional brightness cap on battery
5. **Storage/PCIe** — NVMe power states, ASPM depth
6. **Radios** — WiFi power save, BT/ethernet disable on battery
7. **Background** — Docker auto-stop (Endurance), VM writeback batching

Profile files live in `profiles/` and are sourced at install time.

## v2 Roadmap (not implemented)

Cross-laptop support: auto-detect GPU/CPU/NIC, multi-distro package managers, generic dGPU offload (NVIDIA/AMD/Intel). Same four profiles, mapped to detected hardware.

## Log

`/var/log/battery-optimizer.log`
