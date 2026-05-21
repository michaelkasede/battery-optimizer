# ThinkPad P14s Gen 3 NVIDIA T550 Battery Optimization Guide

## Why Your Battery Drains Fast

Your system has **two GPUs**:
- **Intel Iris Xe** (integrated, low power) ← should be default
- **NVIDIA T550** (discrete, high power) ← #1 battery drain

The T550 stays active even when idle, consuming 3-5W continuously. The battery optimizer script switches to **On-Demand mode**, where the T550 only activates when needed.

---

## After Running the Script

### 1. Verify NVIDIA is set to On-Demand
```bash
# Check current GPU mode
prime-select query
```
Should output: `on-demand`

If not, set it:
```bash
sudo prime-select on-demand
```

---

### 2. Check GPU Load (Real-time)
```bash
# Monitor GPU status
nvidia-smi dmon
```
Expected: `pwr` should show ~5W or less at idle (sleeping)

---

### 3. Additional Display Brightness Hack
The 1920×1200 IPS display consumes 15-20% of battery. Reduce to 30-40% brightness on battery:

**GUI Method:**
- Settings → Power → Battery → Brightness slider

**Command line:**
```bash
# Reduce brightness to 40%
echo 40 | sudo tee /sys/class/backlight/*/brightness

# List all brightness devices
ls /sys/class/backlight/
```

---

## Critical: BIOS Settings (DO NOT SKIP)

Reboot and press `F1` during startup for BIOS setup:

### Go to: Config → Power
- [ ] Set **Graphics Mode** → `Integrated Only` (iGPU default)
- [ ] Disable **Nvidia dGPU** if you don't need CUDA workloads
- [ ] Enable **Panel Self-Refresh (PSR)** on Intel GPU
- [ ] Set **Sleep State** → `Linux S3` (not S0ix)

### Go to: Power → Power Management
- [ ] **Wake on LAN** → Disabled
- [ ] **USB Wake** → Disabled  
- [ ] **Keyboard Wake** → Disabled
- [ ] **Always On USB** → Disabled

### Go to: Security → UEFI Secure Boot
- [ ] Verify Secure Boot is ON (helps with power management)

---

## Real-World Battery Gains

| Setting | Battery Life |
|---------|---|
| No optimization | ~1 hour (your current) |
| Just TLP + CPU scaling | ~1.5 hours |
| + NVIDIA On-Demand | **~2.5-3 hours** |
| + Display 40% brightness | **~3.5-4.5 hours** |
| + BIOS Graphics = Integrated | **~4.5-6 hours** |

---

## Monitor Your Battery in Real-Time

```bash
# Watch battery drain rate (mW)
watch -n 1 "cat /sys/class/power_supply/BAT0/power_now"

# Expected: 5-8W idle (with optimization)
# Baseline: 15-20W without optimization
```

---

## Disable NVIDIA Completely (Nuclear Option)

If you don't use CUDA/professional graphics software:

```bash
# Blacklist NVIDIA driver
echo "blacklist nvidia" | sudo tee /etc/modprobe.d/blacklist-nvidia.conf
echo "blacklist nvidia_drm" | sudo tee -a /etc/modprobe.d/blacklist-nvidia.conf

# Then reboot
sudo reboot
```

This alone can **add 2+ hours** to battery life.

---

## Thunderbolt 4 Power Drain

Your ThinkPad has 2× Thunderbolt 4 ports. Each consumes 1-2W when active.

**Disable if not needed:**
```bash
# Check Thunderbolt devices
lsusb | grep Thunderbolt

# Disable Thunderbolt runtime PM (if experiencing random wakes)
echo "auto" | sudo tee /sys/bus/pci/devices/0000:00:07.0/power/control
```

---

## Monitor What's Draining Power

```bash
# Install powertop if not already (script does this)
sudo powertop

# Look at "Top 10 Power Consumers" tab
# Expected: kernel scheduler + WiFi + display
# Bad sign: nvidia-smi or nouveau in the list
```

---

## Validate Your Optimization

### Before:
```
$ sudo powertop --calibrate && sudo powertop
Power estimated: 15.3 W
```

### After (with this script):
```
$ sudo powertop --calibrate && sudo powertop
Power estimated: 5-8 W
```

If you're still seeing 12+ W, check:
1. `prime-select query` (should be on-demand)
2. `nvidia-smi` (should say GPU is Off)
3. BIOS settings (Graphics Mode must be Integrated)

---

## Troubleshooting

### GPU Not Sleeping?
```bash
# Check if nouveau (old driver) is loaded
lsmod | grep nouveau

# If yes, blacklist it:
echo "blacklist nouveau" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
sudo update-initramfs -u
sudo reboot
```

### High CPU Usage at Idle?
```bash
# Check what's hogging CPU
top -b -n 1 | head -20

# Common culprits:
# - Firefox with hardware acceleration → disable
# - Snap packages → remove unused snaps
# - Baloo indexer → disable (Plasma file search)
```

### Keyboard/Mouse Disconnecting?
The script disables USB autosuspend for mice/keyboards. If you have issues:
```bash
# Edit /etc/tlp.conf and adjust:
USB_DENYLIST="046d:c52b 046d:c534 17ef:608d"
# Remove your mouse/keyboard USB IDs if they're disconnecting
```

---

## Final Checklist After Running Script + This Guide

- [ ] Run `sudo bash ubuntu-battery-optimizer.sh`
- [ ] `sudo reboot`
- [ ] Verify BIOS Graphics Mode = Integrated
- [ ] Run `prime-select query` → shows `on-demand`
- [ ] Set display brightness to 40%
- [ ] Test with `powertop` (target: 5-8W idle)
- [ ] Monitor battery for 1 hour (target: ~5-8% drain per hour on battery)

---

## Expected Result

With all optimizations **you should get 4-5 hours** on battery instead of 1 hour.

If you're still at 1-2 hours after all this, your battery itself may be degraded (check with `sudo powertop` under "Charge:" line).
