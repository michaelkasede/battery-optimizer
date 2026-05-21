# Steam Gaming on Linux — ThinkPad P14s Gen 3

Guide for running Steam games with the **Gaming** profile from [v1.1](../README.md).

The T550 is an entry-level mobile GPU. Expect 720p–1080p/low–medium settings for most modern titles. The goal here is **stable frame rates on AC power**, not battery gaming.

## Before You Start

1. Apply the Gaming profile:

```bash
cd battery-optimizer/v1.1
sudo bash ubuntu-battery-optimizer.sh --mode gaming
sudo reboot
```

2. Verify GPU mode:

```bash
prime-select query    # must show: nvidia
nvidia-smi            # T550 should appear, not "GPU is off"
```

3. **Plug in the power adapter.** Gaming on battery from a 52.5 Wh pack gives ~30–45 minutes and causes severe throttling.

## BIOS Settings for Gaming

Press **F1** at boot → Config → Power:

- **Graphics Mode** → **Hybrid** or **Discrete** (not Integrated Only)
- Disable battery-saving features that limit dGPU power if present

Switch back to **Integrated Only** when returning to Balanced/Endurance profiles.

## Install Steam

```bash
# Ubuntu — enable 32-bit and install Steam
sudo dpkg --add-architecture i386
sudo apt update
sudo apt install steam-installer
steam
```

On first launch, Steam downloads updates and installs the runtime.

## Proton (Windows Games)

Steam → Settings → Compatibility:

- Enable **"Enable Steam Play for supported titles"**
- Enable **"Enable Steam Play for all other titles"**
- Select **Proton Experimental** (or latest Proton version)

Per-game: right-click game → Properties → Compatibility → force a specific Proton version if one game misbehaves.

## Launch Games on the dGPU

With Gaming profile (`prime-select nvidia`), all rendering uses the T550 automatically — no `prime-run` needed.

If you are on **Balanced** or **Performance** (on-demand mode) instead:

```bash
prime-run steam
# or per-game:
prime-run %command%   # in Steam launch options
```

## Recommended Steam Launch Options

For Proton games (set in Properties → Launch Options):

```
PROTON_NO_ESYNC=0 PROTON_NO_FSYNC=0 %command%
```

If a game stutters or crashes:

```
PROTON_USE_WINED3D=0 DXVK_HUD=fps %command%
```

For native Linux games, usually no extra options needed on Gaming profile.

## System Optimizations While Gaming

| Do | Why |
|----|-----|
| Plug in AC adapter | Prevents battery drain and CPU/GPU throttling |
| Close Docker, browsers, IDEs | Frees RAM and CPU for the game |
| Use wired ethernet if possible | Lower latency than WiFi; Gaming profile keeps WiFi PM off on AC |
| Set game to 1080p or 900p | T550 lacks VRAM/throughput for high settings |
| Use medium/low textures | 4 GB VRAM class GPU |
| Keep laptop elevated / cool | thermald is active; thermal throttle cuts FPS |

| Avoid | Why |
|-------|-----|
| Gaming on battery | ~45 min max; turbo disabled; platform power limits |
| Running Endurance/Balanced profile | dGPU asleep or iGPU-only |
| Multiple monitors at high refresh | Increases GPU and display power draw |
| Chrome with many tabs + game | Contention on  shared CPU/GPU |

## Switch Back After Gaming

Battery profiles use iGPU or on-demand mode. Re-apply when done:

```bash
sudo bash ubuntu-battery-optimizer.sh --mode balanced
sudo reboot
```

Set BIOS Graphics Mode back to **Integrated Only** for best battery life.

## Troubleshooting

### Game uses iGPU (low FPS, Intel in logs)

```bash
prime-select query          # should be nvidia
sudo prime-select nvidia && sudo reboot
```

### `nvidia-smi` shows GPU off

Re-run Gaming profile and reboot. Check BIOS is not set to Integrated Only.

### Proton game won't start

1. Verify Proton is enabled for the title
2. Try Proton Experimental vs Proton 9
3. Check [ProtonDB](https://www.protondb.com/) for game-specific fixes
4. Clear prefix: Steam → game → Properties → Installed Files → Verify

### Screen tearing

Enable VSync in game settings, or use compositor VSync in GNOME Settings → Display.

## Expected Performance (T550, rough guide)

| Tier | Examples | Settings |
|------|----------|----------|
| Light | Stardew Valley, Hollow Knight, older Source games | 1080p high |
| Medium | GTA V, Skyrim SE, indie 3D | 1080p medium |
| Heavy | Cyberpunk 2077, Elden Ring | 720p–900p low; may need FSR |

Use MangoHud for FPS overlay:

```bash
sudo apt install mangohud
mangohud %command%    # Steam launch options
```

## Related

- [v1.1 README](../README.md) — profile overview
- [NVIDIA-GPU-BATTERY-GUIDE.md](../../ubuntu+nvidia/NVIDIA-GPU-BATTERY-GUIDE.md) — hybrid graphics deep-dive (v1.0)
