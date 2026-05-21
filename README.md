# Battery Optimizer

Power management scripts for Ubuntu laptops with hybrid Intel + NVIDIA graphics. Built to fix severe battery drain on a **Lenovo ThinkPad P14s Gen 3** (i7-1280P, NVIDIA T550, 52.5 Wh) where unplugged sessions lasted ~1 hour before optimization.

Pre-optimization PowerTOP baseline: **21–23 W** discharge with the NVIDIA T550 fully active.

## Versions

| Folder | Version | Description |
|--------|---------|-------------|
| [`ubuntu+nvidia/`](ubuntu+nvidia/) | **v1.0** | Frozen. Single-profile optimizer hardcoded for ThinkPad P14s Gen 3 |
| [`v1.1/`](v1.1/) | **v1.1** | Four selectable profiles: Performance, Balanced, Endurance, Gaming |
| `v2/` | **v2 (planned)** | Cross-laptop, multi-distro, generic dGPU — not implemented yet |

## Quick Start

### Recommended (v1.1)

```bash
git clone https://github.com/michaelkasede/battery-optimizer.git
cd battery-optimizer/v1.1
sudo bash ubuntu-battery-optimizer.sh
# Or non-interactive:
sudo bash ubuntu-battery-optimizer.sh --mode balanced
sudo bash ubuntu-battery-optimizer.sh --mode gaming
sudo reboot
```

The script shows a profile menu. Press **Enter** for **Balanced** (default), or pick another mode.

### v1.0 (legacy single profile)

```bash
cd battery-optimizer/ubuntu+nvidia
sudo bash ubuntu-battery-optimizer.sh
sudo reboot
```

## Profile Overview (v1.1)

| Profile | Battery (light use) | GPU mode | Best for |
|---------|---------------------|----------|----------|
| **Balanced** | ~3–4 h | on-demand | Daily dev work (default) |
| **Performance** | ~1.5–2 h | on-demand | Heavy builds on battery |
| **Endurance** | ~4–5+ h | intel (iGPU only) | Travel, meetings, email |
| **Gaming** | AC required | nvidia (dGPU) | Steam — plug in power adapter |

See [`v1.1/README.md`](v1.1/README.md) for full usage and [`v1.1/docs/STEAM-GAMING-GUIDE.md`](v1.1/docs/STEAM-GAMING-GUIDE.md) for gaming setup.

## After Running Any Version

1. **Reboot** — required for GRUB, modprobe, and GPU mode changes
2. **BIOS** (ThinkPad F1 at boot): Graphics Mode → **Integrated Only** (except Gaming profile)
3. **Verify**: `bash battery-diagnostic.sh` (from the version folder you ran)

## Repository Layout

```
battery-optimizer/
├── README.md                 ← you are here
├── ubuntu+nvidia/            ← v1.0 (frozen)
│   ├── README.md
│   ├── ubuntu-battery-optimizer.sh
│   ├── battery-diagnostic.sh
│   └── NVIDIA-GPU-BATTERY-GUIDE.md
└── v1.1/                     ← v1.1 (profiles + gaming)
    ├── README.md
    ├── ubuntu-battery-optimizer.sh
    ├── battery-diagnostic.sh
    ├── profiles/
    │   ├── balanced.env
    │   ├── performance.env
    │   ├── endurance.env
    │   └── gaming.env
    └── docs/
        └── STEAM-GAMING-GUIDE.md
```

## Roadmap

- **v1.0** — ThinkPad P14s Gen 3, single balanced profile
- **v1.1** — Four profiles, interactive selection, gaming guide
- **v2 (Powerplay)** — Terminal CLI (`powerplay balanced`, `powerplay saver`, `powerplay gaming`), cross-laptop hardware detection, any Linux distro and dGPU vendor

## License

Use at your own risk. These scripts modify system configuration (TLP, GRUB, NVIDIA drivers, systemd). Review before running on production machines.
