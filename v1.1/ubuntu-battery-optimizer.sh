#!/bin/bash
# ============================================================
#  Ubuntu Battery Optimizer v1.1.0
#  Optimized for: Lenovo ThinkPad P14s Gen 3
#  CPU:  Intel Core i7-1280P | GPU: Iris Xe + NVIDIA T550
#  Run with: sudo bash ubuntu-battery-optimizer.sh
#  Options:
#    --mode MODE               performance|balanced|endurance|gaming
#    --skip-docker-check         Skip Docker daemon warning during install
#    --disable-docker-on-battery Legacy flag; Endurance stops Docker by default
# ============================================================

VERSION="1.1.0"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTED_MODE=""
SKIP_DOCKER_CHECK=0
DISABLE_DOCKER_ON_BATTERY=0

usage() {
  echo "Usage: sudo bash $0 [OPTIONS]"
  echo ""
  echo "  --mode MODE                 performance | balanced | endurance | gaming"
  echo "  --skip-docker-check           Skip Docker warning during install"
  echo "  --disable-docker-on-battery   Force Docker stop on battery (Endurance does this)"
  echo "  -h, --help                    Show this help"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      SELECTED_MODE="${2,,}"
      shift 2
      ;;
    --skip-docker-check) SKIP_DOCKER_CHECK=1; shift ;;
    --disable-docker-on-battery) DISABLE_DOCKER_ON_BATTERY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo -e "${RED}[ERROR]${NC} Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR]${NC} Please run as root: sudo bash $0"
  exit 1
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

select_profile() {
  echo -e "${BOLD}Select power profile:${NC}\n"
  echo -e "  ${CYAN}[1]${NC} Performance  — max responsiveness on battery (~1.5–2h)"
  echo -e "  ${CYAN}[2]${NC} Balanced     — daily dev work (~3–4h)          ${BOLD}[default]${NC}"
  echo -e "  ${CYAN}[3]${NC} Endurance    — maximum battery runtime (~4–5h+)"
  echo -e "  ${CYAN}[4]${NC} Gaming       — Steam / dGPU (AC required)\n"
  read -r -p "  Choice [2]: " choice
  case "${choice:-2}" in
    1) SELECTED_MODE="performance" ;;
    2) SELECTED_MODE="balanced" ;;
    3) SELECTED_MODE="endurance" ;;
    4) SELECTED_MODE="gaming" ;;
    *)
      echo -e "${RED}[ERROR]${NC} Invalid choice"
      exit 1
      ;;
  esac
}

if [[ -z "$SELECTED_MODE" ]]; then
  select_profile
fi

case "$SELECTED_MODE" in
  performance|balanced|endurance|gaming) ;;
  *)
    echo -e "${RED}[ERROR]${NC} Unknown mode: $SELECTED_MODE"
    echo "  Valid modes: performance, balanced, endurance, gaming"
    exit 1
    ;;
esac

PROFILE_FILE="$SCRIPT_DIR/profiles/${SELECTED_MODE}.env"
if [[ ! -f "$PROFILE_FILE" ]]; then
  echo -e "${RED}[ERROR]${NC} Profile not found: $PROFILE_FILE"
  exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_FILE"

# AC defaults (overridden by gaming.env)
CPU_SCALING_GOVERNOR_ON_AC=${CPU_SCALING_GOVERNOR_ON_AC:-performance}
CPU_ENERGY_PERF_POLICY_ON_AC=${CPU_ENERGY_PERF_POLICY_ON_AC:-balance_performance}
CPU_MAX_PERF_ON_AC=${CPU_MAX_PERF_ON_AC:-100}
CPU_BOOST_ON_AC=${CPU_BOOST_ON_AC:-1}
CPU_HWP_DYN_BOOST_ON_AC=${CPU_HWP_DYN_BOOST_ON_AC:-1}
PLATFORM_PROFILE_ON_AC=${PLATFORM_PROFILE_ON_AC:-balanced}
NVME_POWER_MGMT_ON_AC=${NVME_POWER_MGMT_ON_AC:-off}
SATA_LINKPWR_ON_AC=${SATA_LINKPWR_ON_AC:-med_power_with_dipm}
PCIE_ASPM_ON_AC=${PCIE_ASPM_ON_AC:-default}
WIFI_PWR_ON_AC=${WIFI_PWR_ON_AC:-off}

# Legacy flags override profile Docker setting
if [[ "$DISABLE_DOCKER_ON_BATTERY" -eq 1 ]]; then
  DOCKER_ON_BATTERY="stop"
fi

mkdir -p /etc/battery-optimizer
echo "$SELECTED_MODE" > /etc/battery-optimizer/mode

echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "   Ubuntu Battery Optimizer v${VERSION} - ThinkPad P14s Gen 3"
echo "   Profile: ${PROFILE_NAME} — ${PROFILE_TAGLINE}"
echo "   $(date)"
echo "============================================================${NC}"
echo -e "${CYAN}Hardware:${NC} i7-1280P | Iris Xe | NVIDIA T550 | 52.5Wh\n"

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
# STEP 2 — NVIDIA hybrid graphics
# ============================================================
echo -e "\n${BLUE}[2/10]${NC} ${BOLD}NVIDIA T550 hybrid graphics...${NC}"

NVIDIA_BDF=$(detect_nvidia_bdf)
if [[ -z "$NVIDIA_BDF" ]]; then
  NVIDIA_BDF="0000:03:00.0"
  echo -e "  ${YELLOW}⚠${NC} NVIDIA PCI address not detected, using fallback $NVIDIA_BDF"
else
  echo -e "  ${GREEN}✓${NC} Detected NVIDIA at $NVIDIA_BDF"
fi

if command -v prime-select &>/dev/null; then
  prime-select "$PRIME_MODE"
  echo -e "  ${GREEN}✓${NC} NVIDIA set to ${PRIME_MODE}"
fi

cat > /etc/udev/rules.d/80-nvidia-pm.rules << 'EOF'
# NVIDIA - Runtime power management (vendor-wide)
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c06*", TEST=="power/control", ATTR{power/control}="auto"
EOF

cat > /etc/modprobe.d/nvidia-power.conf << EOF
# NVIDIA - Profile: ${PROFILE_NAME} (${SELECTED_MODE})
options nvidia NVreg_DynamicPowerManagement=${NVREG_DPM}
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/tmp
EOF

cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

echo "$NVIDIA_RUNTIME_PM" > "/sys/bus/pci/devices/${NVIDIA_BDF}/power/control" 2>/dev/null
echo -e "  ${GREEN}✓${NC} NVIDIA DPM=${NVREG_DPM}, runtime PM=${NVIDIA_RUNTIME_PM}"
echo -e "  ${GREEN}✓${NC} nouveau blacklisted"

# ============================================================
# STEP 3 — TLP
# ============================================================
echo -e "\n${BLUE}[3/10]${NC} Configuring TLP (${PROFILE_NAME})..."

cat > /etc/tlp.conf << EOF
# TLP Config - ThinkPad P14s Gen 3
# Profile: ${PROFILE_NAME} (${SELECTED_MODE}) | v${VERSION}

TLP_ENABLE=1
TLP_DEFAULT_MODE=AC
TLP_PERSISTENT_DEFAULT=0

# --- CPU ---
CPU_SCALING_GOVERNOR_ON_AC=${CPU_SCALING_GOVERNOR_ON_AC}
CPU_SCALING_GOVERNOR_ON_BAT=${CPU_SCALING_GOVERNOR_ON_BAT}
CPU_ENERGY_PERF_POLICY_ON_AC=${CPU_ENERGY_PERF_POLICY_ON_AC}
CPU_ENERGY_PERF_POLICY_ON_BAT=${CPU_ENERGY_PERF_POLICY_ON_BAT}
CPU_MIN_PERF_ON_AC=0
CPU_MAX_PERF_ON_AC=${CPU_MAX_PERF_ON_AC}
CPU_MIN_PERF_ON_BAT=0
CPU_MAX_PERF_ON_BAT=${CPU_MAX_PERF_ON_BAT}
CPU_BOOST_ON_AC=${CPU_BOOST_ON_AC}
CPU_BOOST_ON_BAT=${CPU_BOOST_ON_BAT}
CPU_HWP_DYN_BOOST_ON_AC=${CPU_HWP_DYN_BOOST_ON_AC}
CPU_HWP_DYN_BOOST_ON_BAT=${CPU_HWP_DYN_BOOST_ON_BAT}

# --- Platform profile ---
PLATFORM_PROFILE_ON_AC=${PLATFORM_PROFILE_ON_AC}
PLATFORM_PROFILE_ON_BAT=${PLATFORM_PROFILE_ON_BAT}

# --- Intel Iris Xe ---
INTEL_GPU_MIN_FREQ_ON_AC=0
INTEL_GPU_MIN_FREQ_ON_BAT=0
INTEL_GPU_MAX_FREQ_ON_BAT=${INTEL_GPU_MAX_FREQ_ON_BAT}
INTEL_GPU_BOOST_FREQ_ON_BAT=${INTEL_GPU_BOOST_FREQ_ON_BAT}

# --- NVMe ---
NVME_POWER_MGMT_ON_AC=${NVME_POWER_MGMT_ON_AC}
NVME_POWER_MGMT_ON_BAT=${NVME_POWER_MGMT_ON_BAT}
SATA_LINKPWR_ON_AC="${SATA_LINKPWR_ON_AC}"
SATA_LINKPWR_ON_BAT="${SATA_LINKPWR_ON_BAT}"
AHCI_RUNTIME_PM_ON_BAT=auto
AHCI_RUNTIME_PM_TIMEOUT=15

# --- PCIe ASPM ---
PCIE_ASPM_ON_AC=${PCIE_ASPM_ON_AC}
PCIE_ASPM_ON_BAT=${PCIE_ASPM_ON_BAT}

# --- Intel AX211 WiFi ---
WIFI_PWR_ON_AC=${WIFI_PWR_ON_AC}
WIFI_PWR_ON_BAT=${WIFI_PWR_ON_BAT}

# --- Radios ---
RESTORE_DEVICE_STATE_ON_STARTUP=0
DEVICES_TO_DISABLE_ON_BAT_NOT_IN_USE="${DEVICES_DISABLE_BAT}"
DEVICES_TO_ENABLE_ON_AC="bluetooth"

# --- USB Autosuspend ---
USB_AUTOSUSPEND=1
USB_AUTOSUSPEND_DISABLE_ON_SHUTDOWN=1
USB_DENYLIST="04f3:2eda 058f:9540 046d:c52b 046d:c534"

# --- ThinkPad battery thresholds ---
START_CHARGE_THRESH_BAT0=${CHARGE_START}
STOP_CHARGE_THRESH_BAT0=${CHARGE_STOP}

# --- NVIDIA: exclude from TLP runtime PM (udev handles it) ---
RUNTIME_PM_ON_AC=auto
RUNTIME_PM_ON_BAT=auto
RUNTIME_PM_DENYLIST="${NVIDIA_BDF}"

# --- Audio ---
SOUND_POWER_SAVE_ON_AC=0
SOUND_POWER_SAVE_ON_BAT=1
SOUND_POWER_SAVE_CONTROLLER=Y

# --- Disk I/O ---
DISK_IDLE_SECS_ON_AC=0
DISK_IDLE_SECS_ON_BAT=${DISK_IDLE_SECS_ON_BAT}
MAX_LOST_WORK_SECS_ON_AC=15
MAX_LOST_WORK_SECS_ON_BAT=${MAX_LOST_WORK_SECS_ON_BAT}
EOF

echo -e "  ${GREEN}✓${NC} TLP configured (charge ${CHARGE_START}%→${CHARGE_STOP}%)"

# ============================================================
# STEP 4 — Intel Iris Xe (i915)
# ============================================================
echo -e "\n${BLUE}[4/10]${NC} Configuring Intel Iris Xe (i915)..."

cat > /etc/modprobe.d/i915-power.conf << EOF
# Intel Iris Xe - Profile: ${PROFILE_NAME}
options i915 enable_psr=${I915_ENABLE_PSR}
options i915 enable_fbc=${I915_ENABLE_FBC}
EOF

echo -e "  ${GREEN}✓${NC} Iris Xe: PSR=${I915_ENABLE_PSR}, FBC=${I915_ENABLE_FBC}"

# ============================================================
# STEP 5 — Intel AX211 WiFi
# ============================================================
echo -e "\n${BLUE}[5/10]${NC} Configuring Intel AX211 WiFi..."

cat > /etc/modprobe.d/iwlwifi-power.conf << 'EOF'
options iwlwifi power_save=1
options iwlwifi uapsd_disable=0
options iwlmvm power_scheme=3
EOF

echo -e "  ${GREEN}✓${NC} AX211: power_save=1, iwlmvm power_scheme=3"

echo -e "\n${BLUE}     ${NC} Rebuilding initramfs for driver options..."
if update-initramfs -u -q; then
  echo -e "  ${GREEN}✓${NC} initramfs updated"
else
  echo -e "  ${RED}✗${NC} initramfs update failed — run: sudo update-initramfs -u"
fi

# ============================================================
# STEP 6 — Kernel power parameters
# ============================================================
echo -e "\n${BLUE}[6/10]${NC} Applying kernel power parameters..."

cat > /etc/sysctl.d/99-battery-optimizer.conf << EOF
# Profile: ${PROFILE_NAME} (${SELECTED_MODE})
vm.dirty_writeback_centisecs = 6000
vm.dirty_expire_centisecs = 6000
vm.laptop_mode = ${VM_LAPTOP_MODE}
net.ipv4.tcp_slow_start_after_idle = 0
EOF

sysctl -p /etc/sysctl.d/99-battery-optimizer.conf -q
echo -e "  ${GREEN}✓${NC} Kernel VM/IO parameters applied (laptop_mode=${VM_LAPTOP_MODE})"

# ============================================================
# STEP 7 — PowerTOP one-shot
# ============================================================
echo -e "\n${BLUE}[7/10]${NC} Running PowerTOP one-shot tune..."

systemctl disable powertop.service 2>/dev/null
systemctl stop powertop.service 2>/dev/null
rm -f /etc/systemd/system/powertop.service

# powertop --auto-tune removed: it overrides TLP's USB/NVIDIA denylists
echo -e "  ${GREEN}✓${NC} PowerTOP auto-tune skipped (TLP is the only configurator)"

# ============================================================
# STEP 8 — Thermald
# ============================================================
echo -e "\n${BLUE}[8/10]${NC} Enabling thermald..."
systemctl enable thermald && systemctl start thermald
echo -e "  ${GREEN}✓${NC} Thermald active"

# ============================================================
# STEP 9 — Brightness cap + Docker on battery
# ============================================================
echo -e "\n${BLUE}[9/10]${NC} Setting up battery-aware services..."

mkdir -p /var/lib/battery-optimizer

if [[ "$BRIGHTNESS_CAP_ENABLED" -eq 1 ]]; then
  cat > /usr/local/bin/battery-brightness-cap.sh << EOF
#!/bin/bash
STATE_FILE=/var/lib/battery-optimizer/brightness-saved
TARGET_PCT=${BRIGHTNESS_CAP_PCT}

is_on_battery() {
  for ac in /sys/class/power_supply/AC* /sys/class/power_supply/ADP*; do
    [[ -f "\$ac/online" ]] || continue
    read -r online < "\$ac/online"
    [[ "\$online" -eq 1 ]] && return 1
  done
  return 0
}

get_brightness_pct() {
  for bl in /sys/class/backlight/intel_backlight /sys/class/backlight/*; do
    [[ -f "\$bl/brightness" && -f "\$bl/max_brightness" ]] || continue
    cur=\$(cat "\$bl/brightness")
    max=\$(cat "\$bl/max_brightness")
    echo \$(( cur * 100 / max ))
    return 0
  done
  return 1
}

set_brightness_pct() {
  local pct=\$1
  for bl in /sys/class/backlight/intel_backlight /sys/class/backlight/*; do
    [[ -f "\$bl/brightness" && -f "\$bl/max_brightness" ]] || continue
    max=\$(cat "\$bl/max_brightness")
    val=\$(( pct * max / 100 ))
    echo "\$val" > "\$bl/brightness"
  done
}

if is_on_battery; then
  if [[ ! -f "\$STATE_FILE" ]]; then
    get_brightness_pct > "\$STATE_FILE" 2>/dev/null || true
  fi
  current=\$(get_brightness_pct 2>/dev/null || echo 100)
  if [[ "\$current" -gt "\$TARGET_PCT" ]]; then
    set_brightness_pct "\$TARGET_PCT"
  fi
else
  if [[ -f "\$STATE_FILE" ]]; then
    saved=\$(cat "\$STATE_FILE")
    set_brightness_pct "\$saved"
    rm -f "\$STATE_FILE"
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
  echo -e "  ${GREEN}✓${NC} Brightness capped to ${BRIGHTNESS_CAP_PCT}% on battery"
else
  systemctl disable battery-brightness.path 2>/dev/null
  systemctl stop battery-brightness.path 2>/dev/null
  echo -e "  ${GREEN}✓${NC} Brightness cap disabled (${PROFILE_NAME})"
fi

# Docker handling
if [[ "$DOCKER_ON_BATTERY" == "stop" ]]; then
  cat > /usr/local/bin/docker-battery-manager.sh << 'EOF'
#!/bin/bash
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
elif [[ "$DOCKER_ON_BATTERY" == "warn" ]] && systemctl is-active docker &>/dev/null && [[ "$SKIP_DOCKER_CHECK" -ne 1 ]]; then
  echo -e "  ${YELLOW}⚠${NC} Docker is running — adds 2–5W idle drain on battery"
  echo -e "    Use ${CYAN}--mode endurance${NC} or ${CYAN}--disable-docker-on-battery${NC} to auto-stop"
else
  systemctl disable docker-battery-manager.path 2>/dev/null
  systemctl stop docker-battery-manager.path 2>/dev/null
fi

# ============================================================
# STEP 10 — GRUB
# ============================================================
echo -e "\n${BLUE}[10/10]${NC} Optimizing GRUB..."

GRUB_FILE="/etc/default/grub"
cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%Y%m%d%H%M)"

CURRENT=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE" | cut -d'"' -f2)

NEW_PARAMS=(
  "quiet" "splash"
  "nmi_watchdog=0"
  "mem_sleep_default=deep"
)

if [[ "$GRUB_PCIE_ASPM" == "force" ]]; then
  NEW_PARAMS+=("pcie_aspm=force")
fi

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
echo -e "  ${GREEN}✓${NC} GRUB optimized"
[[ "$GRUB_PCIE_ASPM" == "force" ]] && \
  echo -e "  ${YELLOW}⚠${NC} pcie_aspm=force — remove from GRUB if WiFi/NVMe unstable"

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

if command -v prime-select &>/dev/null; then
  CURRENT_PRIME=$(prime-select query 2>/dev/null)
  [[ "$CURRENT_PRIME" == "$EXPECTED_PRIME_MODE" ]]
  check "NVIDIA prime mode: ${EXPECTED_PRIME_MODE} (got: ${CURRENT_PRIME:-unknown})" $?
else
  check "NVIDIA prime-select available" 1
fi

if [[ -f "/sys/bus/pci/devices/${NVIDIA_BDF}/power/control" ]]; then
  PM=$(cat "/sys/bus/pci/devices/${NVIDIA_BDF}/power/control")
  [[ "$PM" == "$NVIDIA_RUNTIME_PM" ]]
  check "NVIDIA runtime PM: ${NVIDIA_RUNTIME_PM} (got: $PM)" $?
else
  check "NVIDIA PCI device ${NVIDIA_BDF} present" 1
fi

systemctl is-active tlp &>/dev/null; check "TLP service running" $?
[[ -f /etc/battery-optimizer/mode ]]; check "Profile persisted: $(cat /etc/battery-optimizer/mode 2>/dev/null)" $?

if lsmod | grep -q '^nouveau'; then
  check "nouveau not loaded" 1
else
  check "nouveau not loaded" 0
fi

if is_on_battery && [[ -f /sys/class/power_supply/BAT0/power_now ]]; then
  POWER_W=$(echo "scale=1; $(cat /sys/class/power_supply/BAT0/power_now) / 1000000" | bc)
  echo -e "  ${CYAN}→${NC} Current power draw: ${POWER_W}W (re-check after reboot)"
else
  echo -e "  ${CYAN}→${NC} On AC — power baseline available after reboot on battery"
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
echo "  All Done! — Profile: ${PROFILE_NAME} (v${VERSION})"
echo "============================================================${NC}"

echo -e "\n${BOLD}Applied profile:${NC} ${CYAN}${PROFILE_NAME}${NC} — ${PROFILE_TAGLINE}"
echo -e "${BOLD}Expected battery:${NC} ${PROFILE_BATTERY_HOURS}"

if [[ "$SELECTED_MODE" == "gaming" ]]; then
  echo -e "\n${BOLD}${YELLOW}⚠  GAMING — plug in AC adapter before playing.${NC}"
  echo -e "  See: ${CYAN}docs/STEAM-GAMING-GUIDE.md${NC}"
  echo -e "  BIOS Graphics Mode → ${BOLD}${BIOS_GRAPHICS_HINT}${NC}"
else
  echo -e "\n${BOLD}${RED}⚠  BIOS CHECKLIST (press F1 at boot):${NC}"
  echo -e "  Config → Power → Graphics Mode = ${BOLD}${BIOS_GRAPHICS_HINT}${NC}"
  echo -e "  Enable Panel Self-Refresh (PSR) | Sleep State = Linux S3"
  echo -e "  Disable Wake on LAN, USB Wake, Always On USB"
fi

if [[ "$CHARGE_STOP" -lt 100 ]]; then
  echo -e "\n${YELLOW}⚠  Charge thresholds: ${CHARGE_START}%→${CHARGE_STOP}% (extends cell lifespan, less per-charge capacity)${NC}"
fi

echo -e "\n${YELLOW}Notes:${NC}"
echo -e "  • Switch profiles: re-run with ${CYAN}--mode <name>${NC}"
echo -e "  • Active profile: ${CYAN}/etc/battery-optimizer/mode${NC}"
echo -e "  • Log: $LOGFILE"
echo -e "\n${BOLD}Reboot now:${NC} ${CYAN}sudo reboot${NC}\n"

command -v acpi &>/dev/null && acpi -b
command -v prime-select &>/dev/null && echo "GPU mode: $(prime-select query)"
