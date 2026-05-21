#!/bin/bash
# ============================================================
#  Ubuntu Battery Optimizer
#  Optimized for: Lenovo ThinkPad P14s Gen 3
#  CPU:  Intel Core i7-1280P (12th Gen Alder Lake-P)
#  GPU1: Intel Iris Xe Graphics (i915)
#  GPU2: NVIDIA T550 (discrete)
#  RAM:  48GB DDR4-3200
#  SSD:  Samsung NVMe PM9A1 1TB
#  BAT:  52.5Wh (Celxpert)
#  WiFi: Intel AX211 CNVi
#  Run with: sudo bash ubuntu-battery-optimizer.sh
#  Options:
#    --skip-docker-check         Skip Docker daemon warning during install
#    --disable-docker-on-battery Stop Docker automatically when unplugged
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKIP_DOCKER_CHECK=0
DISABLE_DOCKER_ON_BATTERY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-docker-check) SKIP_DOCKER_CHECK=1 ;;
    --disable-docker-on-battery) DISABLE_DOCKER_ON_BATTERY=1 ;;
    -h|--help)
      echo "Usage: sudo bash $0 [--skip-docker-check] [--disable-docker-on-battery]"
      exit 0
      ;;
    *)
      echo -e "${RED}[ERROR]${NC} Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR]${NC} Please run as root: sudo bash $0"; exit 1
fi

LOGFILE="/var/log/battery-optimizer.log"
exec > >(tee -a "$LOGFILE") 2>&1

detect_nvidia_bdf() {
  lspci -D -nn 2>/dev/null | grep -iE 'nvidia.*(\[0300\]|\[0302\]|\[030\]|vga|3d)' | awk '{print $1}' | head -1
}

is_on_battery() {
  for ac in /sys/class/power_supply/AC* /sys/class/power_supply/ADP*; do
    [[ -f "$ac/online" ]] || continue
    read -r online < "$ac/online"
    [[ "$online" -eq 1 ]] && return 1
  done
  return 0
}

echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "   Ubuntu Battery Optimizer - ThinkPad P14s Gen 3"
echo "   $(date)"
echo "============================================================${NC}"
echo -e "${CYAN}Hardware:${NC} i7-1280P | Iris Xe | ${RED}NVIDIA T550 ← #1 drain${NC} | 52.5Wh\n"

# ============================================================
# STEP 1 — Install required tools
# ============================================================
echo -e "${BLUE}[1/10]${NC} Installing power management tools..."
apt update -qq

for pkg in tlp tlp-rdw powertop thermald acpi acpid nvidia-prime; do
  if dpkg -l "$pkg" &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $pkg already installed"
  else
    apt install -y "$pkg" -qq && \
      echo -e "  ${GREEN}✓${NC} $pkg installed" || \
      echo -e "  ${RED}✗${NC} Failed: $pkg"
  fi
done

systemctl disable laptop-mode 2>/dev/null
systemctl stop laptop-mode 2>/dev/null

# ============================================================
# STEP 2 — NVIDIA T550: On-Demand mode (most critical step)
# On-Demand = iGPU handles display, dGPU only wakes for load
# ============================================================
echo -e "\n${BLUE}[2/10]${NC} ${BOLD}NVIDIA T550 hybrid graphics (most critical)...${NC}"

NVIDIA_BDF=$(detect_nvidia_bdf)
if [[ -z "$NVIDIA_BDF" ]]; then
  NVIDIA_BDF="0000:03:00.0"
  echo -e "  ${YELLOW}⚠${NC} NVIDIA PCI address not detected, using fallback $NVIDIA_BDF"
else
  echo -e "  ${GREEN}✓${NC} Detected NVIDIA at $NVIDIA_BDF"
fi

if command -v prime-select &>/dev/null; then
  prime-select on-demand
  echo -e "  ${GREEN}✓${NC} NVIDIA set to On-Demand (iGPU default, T550 sleeps when idle)"
fi

# Enable NVIDIA runtime PM via udev
cat > /etc/udev/rules.d/80-nvidia-pm.rules << 'EOF'
# NVIDIA T550 - ThinkPad P14s Gen 3 - Runtime power management
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c06*", TEST=="power/control", ATTR{power/control}="auto"
EOF

# Fine-grained NVIDIA power management
cat > /etc/modprobe.d/nvidia-power.conf << 'EOF'
# NVIDIA T550 - Fine-grained runtime power management
# 0x02 = fine-grained power control (best battery saving)
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/tmp
EOF

# Blacklist nouveau fallback driver
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
# Prevent nouveau from loading instead of proprietary NVIDIA driver
blacklist nouveau
options nouveau modeset=0
EOF

# Apply immediately if GPU is present
echo "auto" > "/sys/bus/pci/devices/${NVIDIA_BDF}/power/control" 2>/dev/null
echo -e "  ${GREEN}✓${NC} NVIDIA dynamic power management = fine-grained (0x02)"
echo -e "  ${GREEN}✓${NC} nouveau blacklisted"

# ============================================================
# STEP 3 — TLP with i7-1280P + ThinkPad charge thresholds
# ============================================================
echo -e "\n${BLUE}[3/10]${NC} Configuring TLP for i7-1280P..."

cat > /etc/tlp.conf << EOF
# TLP Config - ThinkPad P14s Gen 3
# CPU: i7-1280P (6P+8E cores) | GPU: Iris Xe + NVIDIA T550

TLP_ENABLE=1
TLP_DEFAULT_MODE=AC
TLP_PERSISTENT_DEFAULT=0

# --- CPU: i7-1280P ---
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power
CPU_MIN_PERF_ON_AC=0
CPU_MAX_PERF_ON_AC=100
CPU_MIN_PERF_ON_BAT=0
CPU_MAX_PERF_ON_BAT=35
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0
CPU_HWP_DYN_BOOST_ON_AC=1
CPU_HWP_DYN_BOOST_ON_BAT=0

# --- Platform profile ---
PLATFORM_PROFILE_ON_AC=balanced
PLATFORM_PROFILE_ON_BAT=low-power

# --- Intel Iris Xe ---
INTEL_GPU_MIN_FREQ_ON_AC=0
INTEL_GPU_MIN_FREQ_ON_BAT=0
INTEL_GPU_MAX_FREQ_ON_BAT=300
INTEL_GPU_BOOST_FREQ_ON_BAT=450

# --- Samsung NVMe PM9A1 ---
NVME_POWER_MGMT_ON_AC=off
NVME_POWER_MGMT_ON_BAT=med_power_with_dipm
SATA_LINKPWR_ON_AC="med_power_with_dipm"
SATA_LINKPWR_ON_BAT="min_power"
AHCI_RUNTIME_PM_ON_BAT=auto
AHCI_RUNTIME_PM_TIMEOUT=15

# --- PCIe ASPM ---
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave

# --- Intel AX211 WiFi ---
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on

# --- Bluetooth + Ethernet (disable when not in use on battery) ---
RESTORE_DEVICE_STATE_ON_STARTUP=0
DEVICES_TO_DISABLE_ON_BAT_NOT_IN_USE="bluetooth nfc ethernet"
DEVICES_TO_ENABLE_ON_AC="bluetooth"

# --- USB Autosuspend ---
USB_AUTOSUSPEND=1
USB_AUTOSUSPEND_DISABLE_ON_SHUTDOWN=1
# Exclude: Goodix fingerprint (04f3), smart card, keyboard/mouse
USB_DENYLIST="04f3:2eda 058f:9540 046d:c52b 046d:c534"

# --- ThinkPad P14s battery health thresholds ---
START_CHARGE_THRESH_BAT0=40
STOP_CHARGE_THRESH_BAT0=80

# --- NVIDIA T550: exclude from TLP runtime PM (udev handles it) ---
RUNTIME_PM_ON_AC=auto
RUNTIME_PM_ON_BAT=auto
RUNTIME_PM_DENYLIST="${NVIDIA_BDF}"

# --- Intel SOF HDA audio ---
SOUND_POWER_SAVE_ON_AC=0
SOUND_POWER_SAVE_ON_BAT=1
SOUND_POWER_SAVE_CONTROLLER=Y

# --- Disk I/O scheduler ---
DISK_IDLE_SECS_ON_AC=0
DISK_IDLE_SECS_ON_BAT=2
MAX_LOST_WORK_SECS_ON_AC=15
MAX_LOST_WORK_SECS_ON_BAT=60
EOF

echo -e "  ${GREEN}✓${NC} TLP configured with ThinkPad charge thresholds (40-80%)"

# ============================================================
# STEP 4 — Intel Iris Xe (i915) power saving
# ============================================================
echo -e "\n${BLUE}[4/10]${NC} Configuring Intel Iris Xe (i915)..."

cat > /etc/modprobe.d/i915-power.conf << 'EOF'
# Intel Iris Xe - Alder Lake-P (ThinkPad P14s Gen 3)
# PSR2 = Panel Self Refresh v2 (big win on 1920x1200 display)
# FBC  = Frame Buffer Compression
# RC6  = Render C-state 6 (deepest GPU sleep)
options i915 enable_psr=2
options i915 enable_fbc=1
options i915 enable_rc6=7
options i915 lvds_downclock=1
EOF

echo -e "  ${GREEN}✓${NC} Iris Xe: PSR2 + FBC + RC6 enabled"

# ============================================================
# STEP 5 — Intel AX211 WiFi power saving
# ============================================================
echo -e "\n${BLUE}[5/10]${NC} Configuring Intel AX211 WiFi..."

cat > /etc/modprobe.d/iwlwifi-power.conf << 'EOF'
# Intel AX211 CNVi - ThinkPad P14s Gen 3
options iwlwifi power_save=1
options iwlwifi uapsd_disable=0
options iwlmvm power_scheme=3
EOF

echo -e "  ${GREEN}✓${NC} AX211: power_save=1, iwlmvm power_scheme=3"

# ============================================================
# Rebuild initramfs after modprobe changes
# ============================================================
echo -e "\n${BLUE}     ${NC} Rebuilding initramfs for driver options..."
if update-initramfs -u -q; then
  echo -e "  ${GREEN}✓${NC} initramfs updated (nvidia, i915, iwlwifi, nouveau)"
else
  echo -e "  ${RED}✗${NC} initramfs update failed — run manually: sudo update-initramfs -u"
fi

# ============================================================
# STEP 6 — Kernel power parameters
# ============================================================
echo -e "\n${BLUE}[6/10]${NC} Applying kernel power parameters..."

cat > /etc/sysctl.d/99-battery-optimizer.conf << 'EOF'
# ThinkPad P14s Gen 3 - Kernel Power Parameters
vm.dirty_writeback_centisecs = 6000
vm.dirty_expire_centisecs = 6000
vm.laptop_mode = 5
net.ipv4.tcp_slow_start_after_idle = 0
EOF

sysctl -p /etc/sysctl.d/99-battery-optimizer.conf -q
echo -e "  ${GREEN}✓${NC} Kernel VM/IO parameters applied"

# ============================================================
# STEP 7 — PowerTOP one-shot (TLP is primary; no recurring service)
# ============================================================
echo -e "\n${BLUE}[7/10]${NC} Running PowerTOP one-shot tune..."

# Remove recurring service to avoid overwriting TLP settings on every boot/resume
systemctl disable powertop.service 2>/dev/null
systemctl stop powertop.service 2>/dev/null
rm -f /etc/systemd/system/powertop.service

if command -v powertop &>/dev/null; then
  powertop --auto-tune 2>/dev/null
  echo -e "  ${GREEN}✓${NC} PowerTOP tuned once (TLP remains primary configurator)"
else
  echo -e "  ${YELLOW}⚠${NC} PowerTOP not available"
fi

# ============================================================
# STEP 8 — Thermald
# ============================================================
echo -e "\n${BLUE}[8/10]${NC} Enabling thermald..."
systemctl enable thermald && systemctl start thermald
echo -e "  ${GREEN}✓${NC} Thermald active (prevents thermal spikes)"

# ============================================================
# STEP 9 — Brightness cap + optional Docker on battery
# ============================================================
echo -e "\n${BLUE}[9/10]${NC} Setting up battery-aware services..."

mkdir -p /var/lib/battery-optimizer

cat > /usr/local/bin/battery-brightness-cap.sh << 'EOF'
#!/bin/bash
# Cap display brightness on battery; restore saved level on AC
STATE_FILE=/var/lib/battery-optimizer/brightness-saved
TARGET_PCT=40

is_on_battery() {
  for ac in /sys/class/power_supply/AC* /sys/class/power_supply/ADP*; do
    [[ -f "$ac/online" ]] || continue
    read -r online < "$ac/online"
    [[ "$online" -eq 1 ]] && return 1
  done
  return 0
}

get_brightness_pct() {
  for bl in /sys/class/backlight/intel_backlight /sys/class/backlight/*; do
    [[ -f "$bl/brightness" && -f "$bl/max_brightness" ]] || continue
    cur=$(cat "$bl/brightness")
    max=$(cat "$bl/max_brightness")
    echo $(( cur * 100 / max ))
    return 0
  done
  return 1
}

set_brightness_pct() {
  local pct=$1
  for bl in /sys/class/backlight/intel_backlight /sys/class/backlight/*; do
    [[ -f "$bl/brightness" && -f "$bl/max_brightness" ]] || continue
    max=$(cat "$bl/max_brightness")
    val=$(( pct * max / 100 ))
    echo "$val" > "$bl/brightness"
  done
}

if is_on_battery; then
  if [[ ! -f "$STATE_FILE" ]]; then
    get_brightness_pct > "$STATE_FILE" 2>/dev/null || true
  fi
  current=$(get_brightness_pct 2>/dev/null || echo 100)
  if [[ "$current" -gt "$TARGET_PCT" ]]; then
    set_brightness_pct "$TARGET_PCT"
  fi
else
  if [[ -f "$STATE_FILE" ]]; then
    saved=$(cat "$STATE_FILE")
    set_brightness_pct "$saved"
    rm -f "$STATE_FILE"
  fi
fi
EOF
chmod +x /usr/local/bin/battery-brightness-cap.sh

cat > /etc/systemd/system/battery-brightness.service << 'EOF'
[Unit]
Description=Cap display brightness on battery
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/battery-brightness-cap.sh
EOF

cat > /etc/systemd/system/battery-brightness.path << 'EOF'
[Unit]
Description=Watch power source for brightness cap

[Path]
PathChanged=/sys/class/power_supply/BAT0/status
PathChanged=/sys/class/power_supply/ADP0/online
PathChanged=/sys/class/power_supply/ADP1/online
PathChanged=/sys/class/power_supply/AC/online

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable battery-brightness.path
systemctl start battery-brightness.path
/usr/local/bin/battery-brightness-cap.sh 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} Brightness capped to 40% on battery (restores on AC)"

# Docker handling
if systemctl is-active docker &>/dev/null && [[ "$SKIP_DOCKER_CHECK" -ne 1 ]]; then
  echo -e "  ${YELLOW}⚠${NC} Docker is running — adds 2-5W idle drain on battery"
  echo -e "    Re-run with ${CYAN}--disable-docker-on-battery${NC} to stop Docker when unplugged"
fi

if [[ "$DISABLE_DOCKER_ON_BATTERY" -eq 1 ]]; then
  cat > /usr/local/bin/docker-battery-manager.sh << 'EOF'
#!/bin/bash
# Stop Docker when on battery; restart when back on AC (if it was running)
FLAG_FILE=/var/lib/battery-optimizer/docker-was-running

is_on_battery() {
  for ac in /sys/class/power_supply/AC* /sys/class/power_supply/ADP*; do
    [[ -f "$ac/online" ]] || continue
    read -r online < "$ac/online"
    [[ "$online" -eq 1 ]] && return 1
  done
  return 0
}

if is_on_battery; then
  if systemctl is-active docker &>/dev/null; then
    touch "$FLAG_FILE"
    systemctl stop docker docker.socket containerd 2>/dev/null
  fi
else
  if [[ -f "$FLAG_FILE" ]]; then
    systemctl start containerd docker 2>/dev/null
    rm -f "$FLAG_FILE"
  fi
fi
EOF
  chmod +x /usr/local/bin/docker-battery-manager.sh

  cat > /etc/systemd/system/docker-battery-manager.service << 'EOF'
[Unit]
Description=Stop Docker when running on battery
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-battery-manager.sh
EOF

  cat > /etc/systemd/system/docker-battery-manager.path << 'EOF'
[Unit]
Description=Watch power source for Docker battery management

[Path]
PathChanged=/sys/class/power_supply/BAT0/status
PathChanged=/sys/class/power_supply/ADP0/online
PathChanged=/sys/class/power_supply/ADP1/online
PathChanged=/sys/class/power_supply/AC/online

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable docker-battery-manager.path
  systemctl start docker-battery-manager.path
  echo -e "  ${GREEN}✓${NC} Docker will stop automatically when unplugged"
fi

# ============================================================
# STEP 10 — GRUB: Alder Lake-P + NVMe + NVIDIA optimizations
# ============================================================
echo -e "\n${BLUE}[10/10]${NC} Optimizing GRUB for Alder Lake-P + NVIDIA hybrid..."

GRUB_FILE="/etc/default/grub"
cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%Y%m%d%H%M)"

CURRENT=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE" | cut -d'"' -f2)

NEW_PARAMS=(
  "quiet" "splash"
  "nmi_watchdog=0"
  "mem_sleep_default=deep"
  "pcie_aspm=force"
  "i915.enable_psr=2"
  "i915.enable_fbc=1"
  "i915.enable_rc6=7"
  "nvme_core.default_ps_max_latency_us=5500"
  "intel_idle.max_cstate=9"
  "usbcore.autosuspend=5"
)

MERGED="$CURRENT"
for param in "${NEW_PARAMS[@]}"; do
  key=$(echo "$param" | cut -d'=' -f1)
  if ! echo "$MERGED" | grep -q "$key"; then
    MERGED="$MERGED $param"
  fi
done
MERGED=$(echo "$MERGED" | xargs)

sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$MERGED\"|" "$GRUB_FILE"
update-grub -q 2>/dev/null
echo -e "  ${GREEN}✓${NC} GRUB optimized (Alder Lake C-states + NVMe PS latency)"
echo -e "  ${YELLOW}⚠${NC} pcie_aspm=force can cause WiFi/NVMe issues — remove from GRUB if unstable"

# Start TLP
systemctl enable tlp && systemctl restart tlp && tlp start 2>/dev/null

# ============================================================
# VERIFICATION
# ============================================================
echo -e "\n${BOLD}${BLUE}Verification${NC}"

PASS=0
FAIL=0

check() {
  local label="$1" result="$2"
  if [[ "$result" -eq 0 ]]; then
    echo -e "  ${GREEN}✓${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $label"
    FAIL=$((FAIL + 1))
  fi
}

# prime-select
if command -v prime-select &>/dev/null; then
  MODE=$(prime-select query 2>/dev/null)
  [[ "$MODE" == "on-demand" ]]; check "NVIDIA prime mode: on-demand (got: ${MODE:-unknown})" $?
else
  check "NVIDIA prime-select available" 1
fi

# NVIDIA runtime PM
if [[ -f "/sys/bus/pci/devices/${NVIDIA_BDF}/power/control" ]]; then
  PM=$(cat "/sys/bus/pci/devices/${NVIDIA_BDF}/power/control")
  [[ "$PM" == "auto" ]]; check "NVIDIA runtime PM: auto (got: $PM)" $?
else
  check "NVIDIA PCI device ${NVIDIA_BDF} present" 1
fi

# TLP
systemctl is-active tlp &>/dev/null; check "TLP service running" $?

# nouveau not loaded
if lsmod | grep -q '^nouveau'; then
  check "nouveau not loaded" 1
else
  check "nouveau not loaded" 0
fi

# initramfs blacklist present
[[ -f /etc/modprobe.d/blacklist-nouveau.conf ]]; check "nouveau blacklist configured" $?

# Power draw baseline (only meaningful on battery)
if is_on_battery && [[ -f /sys/class/power_supply/BAT0/power_now ]]; then
  POWER_MW=$(cat /sys/class/power_supply/BAT0/power_now)
  POWER_W=$(echo "scale=1; $POWER_MW / 1000000" | bc)
  echo -e "  ${CYAN}→${NC} Current power draw: ${POWER_W}W (re-check after reboot for accurate baseline)"
else
  echo -e "  ${CYAN}→${NC} On AC — power draw baseline available after reboot on battery"
fi

echo -e "\n  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"

if [[ -f "$SCRIPT_DIR/battery-diagnostic.sh" ]]; then
  echo -e "\n${BOLD}${BLUE}Running battery diagnostic...${NC}\n"
  bash "$SCRIPT_DIR/battery-diagnostic.sh"
fi

# ============================================================
# SUMMARY
# ============================================================
echo -e "\n${BOLD}${CYAN}"
echo "============================================================"
echo "  All Done! - ThinkPad P14s Gen 3"
echo "============================================================${NC}"

echo -e "\n${BOLD}What was optimized:${NC}\n"
echo -e "  ${RED}NVIDIA T550${NC}  On-Demand mode + fine-grained PM (NVreg=0x02) at ${NVIDIA_BDF}"
echo -e "  ${CYAN}i7-1280P${NC}     powersave governor, boost off, max 35% on battery"
echo -e "  ${CYAN}Iris Xe${NC}      PSR2 + FBC + RC6 render power states"
echo -e "  ${CYAN}AX211 WiFi${NC}   power_save=1 + iwlmvm power_scheme=3"
echo -e "  ${CYAN}NVMe PM9A1${NC}   med_power_with_dipm on battery"
echo -e "  ${CYAN}ThinkPad BAT${NC} Charge thresholds 40%→80% (extends lifespan)"
echo -e "  ${CYAN}Display${NC}      Auto-cap to 40% brightness on battery"
echo -e "  ${CYAN}GRUB${NC}         deep sleep + NVMe PS + Alder Lake C-states"
echo -e "  ${CYAN}PowerTOP${NC}     one-shot tune (TLP is primary configurator)"

echo -e "\n${YELLOW}Expected battery life:${NC}"
echo -e "  Before optimizing : ~1 hour  (NVIDIA T550 always active)"
echo -e "  After optimizing  : ~3-4 hrs (T550 sleeping, iGPU only)"
echo -e "  + BIOS Integrated : ~4-5 hrs (see checklist below)"

echo -e "\n${BOLD}${RED}⚠  BIOS CHECKLIST — DO NOT SKIP (press F1 at boot):${NC}"
echo -e "  Config → Power → Graphics Mode = ${BOLD}Integrated Only${NC}"
echo -e "  Config → Power → Enable Panel Self-Refresh (PSR)"
echo -e "  Config → Power → Sleep State = ${BOLD}Linux S3${NC}"
echo -e "  Power  → Disable Wake on LAN, USB Wake, Always On USB"

echo -e "\n${YELLOW}⚠  Charge threshold note:${NC}"
echo -e "  Battery charges only between 40%–80% to extend cell lifespan."
echo -e "  Usable capacity per charge is ~21 Wh (40% of 52.5 Wh), not the full pack."
echo -e "  Adjust START/STOP_CHARGE_THRESH in /etc/tlp.conf if you need more runtime."

echo -e "\n${YELLOW}⚠  Other notes:${NC}"
echo -e "  • For CUDA/GPU workloads use: ${CYAN}prime-run <app>${NC}"
echo -e "  • Close Docker/Chrome when on battery unless needed"
echo -e "  • Log: $LOGFILE"
echo -e "\n${BOLD}Reboot now:${NC} ${CYAN}sudo reboot${NC}\n"

command -v acpi &>/dev/null && acpi -b
command -v prime-select &>/dev/null && echo "GPU mode: $(prime-select query)"
