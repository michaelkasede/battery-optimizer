# Gaming with battery-optimizer

v1.2 has no Gaming mode and never switches the whole system to the discrete
GPU. The dGPU stays in on-demand mode and powers itself off when idle. A game
uses the dGPU only when you launch it that way, and the Performance profile is
held while the game runs.

## Steam launch options

Steam → right-click the game → **Properties** → **Launch Options**:

| dGPU | Launch options |
|---|---|
| NVIDIA | `tlpctl launch -p performance prime-run %command%` |
| AMD | `tlpctl launch -p performance env DRI_PRIME=1 %command%` |

- `tlpctl launch -p performance …` holds the TLP **performance** profile while
  the game runs, then returns to the profile you had before. You can see the
  hold with `tlpctl list-holds`. No sudo is needed.
- `prime-run` (from `nvidia-prime`) / `DRI_PRIME=1` render the game on the dGPU.
- Proton options combine as usual, e.g.
  `tlpctl launch -p performance prime-run env DXVK_HUD=fps %command%`.

Outside Steam:

```bash
tlpctl launch -p performance prime-run ./game        # NVIDIA
tlpctl launch -p performance env DRI_PRIME=1 ./game  # AMD
```

## Verify the dGPU is used

```bash
prime-run glxinfo -B | grep -i 'renderer'      # NVIDIA renderer expected
DRI_PRIME=1 glxinfo -B | grep -i 'renderer'    # AMD dGPU renderer expected
nvidia-smi                                     # game process listed while it runs
```

After you quit, the dGPU should go back to sleep within a few seconds:

```bash
cat /sys/bus/pci/devices/<dGPU address>/power/runtime_status   # suspended
battery-optimizer status                                       # shows the address
```

## Tips

- **Play on AC.** A 52.5 Wh battery lasts well under an hour with the dGPU
  busy, and the firmware limits power on battery.
- A dGPU that drives display outputs (VGA controller, shown by
  `battery-optimizer status`) wakes up whenever an external monitor is
  connected to one of its ports. That is expected.
- The P14s Gen 3's T550 is an entry-level GPU (4 GB). Aim for 720p–1080p at
  low or medium settings in recent 3D games.
- MangoHud gives an FPS overlay: `sudo apt install mangohud`, then
  `tlpctl launch -p performance prime-run mangohud %command%`.

## Troubleshooting

| Symptom | Check |
|---|---|
| Game runs on the iGPU | The launch option is missing `prime-run` / `DRI_PRIME=1`. `prime-select query` must print `on-demand` |
| `prime-run: command not found` | `sudo apt install nvidia-prime` |
| `nvidia-smi` fails | Proprietary driver missing: `sudo ubuntu-drivers install`, then reboot |
| dGPU never suspends after gaming | `nvidia-smi` lists processes still using it; `sudo fuser -v /dev/nvidia*` |
| Profile stays on Performance | A launcher is still running. Check `tlpctl list-holds` |

Coming from v1.1: the old Gaming profile (`prime-select nvidia`,
`NVreg_DynamicPowerManagement=0x00`) kept the dGPU on all the time and needed a
reboot to switch. It is gone.
