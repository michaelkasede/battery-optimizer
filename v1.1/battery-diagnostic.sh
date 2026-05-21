#!/bin/bash
# ============================================================
# Battery Health & GPU Power Diagnostic v1.1
# For ThinkPad P14s Gen 3
# Run: bash battery-diagnostic.sh
# ============================================================

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

is_on_battery() {
  for ac in /sys/class/power_supply/AC* /sys/class/power_supply/ADP*; do
    [[ -f "$ac/online" ]] || continue
    read -r online < "$ac/online"
    [[ "$online" -eq 1 ]] && return 1
  done
  return 0
}

ACTIVE_PROFILE=""
ACTIVE_PROFILE_FILE="/etc/battery-optimizer/mode"
if [[ -f "$ACTIVE_PROFILE_FILE" ]]; then
  ACTIVE_PROFILE=$(cat "$ACTIVE_PROFILE_FILE")
fi

echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Battery & Power Diagnostic v1.1 - ThinkPad P14s Gen 3${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}\n"

# ============================================================
# 0. ACTIVE PROFILE
# ============================================================
echo -e "${BOLD}[0] ACTIVE PROFILE${NC}"
if [[ -n "$ACTIVE_PROFILE" ]]; then
  PROFILE_ENV="$SCRIPT_DIR/profiles/${ACTIVE_PROFILE}.env"
  if [[ -f "$PROFILE_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$PROFILE_ENV"
    echo -e "  Profile: ${CYAN}${PROFILE_NAME}${NC} (${ACTIVE_PROFILE})"
    echo -e "  ${PROFILE_TAGLINE}"
    echo -e "  Expected battery: ${PROFILE_BATTERY_HOURS}"
  else
    echo -e "  Profile: ${CYAN}${ACTIVE_PROFILE}${NC} (env file not found locally)"
  fi
else
  echo -e "  ${YELLOW}No profile configured${NC} → Run: ${CYAN}sudo bash ubuntu-battery-optimizer.sh${NC}"
fi

# ============================================================
# 1. BATTERY STATUS
# ============================================================
echo -e "\n${BOLD}[1] BATTERY STATUS${NC}"
if command -v acpi &>/dev/null; then
  acpi -b
  echo ""

  BAT_PATH="/sys/class/power_supply/BAT0"
  if [[ -d "$BAT_PATH" ]]; then
    CURRENT=$(cat "$BAT_PATH/power_now" 2>/dev/null)
    CAPACITY=$(cat "$BAT_PATH/capacity" 2>/dev/null)
    STATUS=$(cat "$BAT_PATH/status" 2>/dev/null)
    ENERGY_FULL=$(cat "$BAT_PATH/energy_full" 2>/dev/null)
    ENERGY_FULL_DESIGN=$(cat "$BAT_PATH/energy_full_design" 2>/dev/null)

    echo -e "  Current Power Draw: ${CYAN}$(echo "scale=2; $CURRENT/1000000" | bc)W${NC}"
    echo -e "  Battery Capacity: ${YELLOW}${CAPACITY}%${NC}"
    echo -e "  Status: $STATUS"

    if [[ -n "$ENERGY_FULL" && -n "$ENERGY_FULL_DESIGN" ]]; then
      HEALTH=$(echo "scale=1; $ENERGY_FULL * 100 / $ENERGY_FULL_DESIGN" | bc)
      if (( $(echo "$HEALTH < 80" | bc -l) )); then
        echo -e "  Battery Health: ${RED}${HEALTH}% (degraded)${NC}"
      else
        echo -e "  Battery Health: ${GREEN}${HEALTH}% (good)${NC}"
      fi
    fi
  fi
fi

# ============================================================
# 2. NVIDIA GPU STATUS
# ============================================================
echo -e "\n${BOLD}[2] NVIDIA GPU STATUS${NC}"

EXPECTED_PRIME="${EXPECTED_PRIME_MODE:-on-demand}"

if command -v nvidia-smi &>/dev/null; then
  nvidia-smi --query-gpu=index,name,driver_version,power.draw,power.limit,utilization.gpu,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null | while IFS=',' read -r idx name driver pwr limit util temp; do
    echo -e "  GPU: ${CYAN}${name}${NC}"
    echo -e "    Driver: $driver"
    echo -e "    Power Draw: ${pwr}W / ${limit}W"
    echo -e "    Utilization: ${util}%"
    echo -e "    Temperature: ${temp}°C"
  done

  echo ""
  PWR=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | head -1)
  if [[ -n "$PWR" ]]; then
    if (( $(echo "$PWR < 1" | bc -l) )); then
      echo -e "  GPU State: ${GREEN}✓ Sleeping (< 1W)${NC}"
    elif (( $(echo "$PWR < 5" | bc -l) )); then
      echo -e "  GPU State: ${YELLOW}⚠ Low power (1–5W)${NC}"
    else
      echo -e "  GPU State: ${RED}✗ Active (>5W)${NC}"
    fi
  fi

  if command -v prime-select &>/dev/null; then
    MODE=$(prime-select query 2>/dev/null)
    echo -e "  Prime Mode: ${CYAN}${MODE}${NC}"
    if [[ "$MODE" != "$EXPECTED_PRIME" ]]; then
      echo -e "    ${RED}→ Expected '${EXPECTED_PRIME}' for ${ACTIVE_PROFILE:-unknown} profile${NC}"
      echo -e "    ${RED}→ Re-run: sudo bash ubuntu-battery-optimizer.sh --mode ${ACTIVE_PROFILE:-balanced}${NC}"
    fi
  fi
else
  echo -e "  ${YELLOW}NVIDIA drivers not installed${NC}"
fi

# ============================================================
# 3. DISPLAY BRIGHTNESS
# ============================================================
echo -e "\n${BOLD}[3] DISPLAY (1920×1200 IPS)${NC}"

if [[ -d /sys/class/backlight ]]; then
  for device in /sys/class/backlight/*; do
    [[ -d "$device" ]] || continue
    DEV=$(basename "$device")
    CURRENT=$(cat "$device/brightness" 2>/dev/null)
    MAX=$(cat "$device/max_brightness" 2>/dev/null)
    PCT=$((CURRENT * 100 / MAX))
    echo -e "  ${DEV}: ${CYAN}${PCT}%${NC} ($CURRENT / $MAX)"
  done
  if [[ "${BRIGHTNESS_CAP_ENABLED:-0}" -eq 1 ]]; then
    echo -e "  ${YELLOW}Profile caps brightness to ${BRIGHTNESS_CAP_PCT}% on battery${NC}"
  fi
fi

# ============================================================
# 4. CPU FREQUENCY SCALING
# ============================================================
echo -e "\n${BOLD}[4] CPU FREQUENCY SCALING${NC}"

if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
  GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
  FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq 2>/dev/null)
  FREQ_MHZ=$((FREQ / 1000))

  echo -e "  Governor: ${CYAN}${GOVERNOR}${NC}"
  echo -e "  Current Frequency: ${FREQ_MHZ}MHz"

  if is_on_battery; then
    if [[ "$GOVERNOR" == "powersave" ]]; then
      echo -e "  Status: ${GREEN}✓ Powersave on battery${NC}"
    else
      echo -e "  Status: ${YELLOW}⚠ ${GOVERNOR} on battery${NC}"
    fi
  else
    echo -e "  Status: ${GREEN}✓ On AC power${NC}"
  fi
fi

# ============================================================
# 5. TLP STATUS
# ============================================================
echo -e "\n${BOLD}[5] POWER MANAGEMENT (TLP)${NC}"

if systemctl is-active tlp &>/dev/null; then
  echo -e "  TLP Status: ${GREEN}✓ Running${NC}"
  tlp-stat -s 2>&1 | grep -E "AC|Battery|Mode" | head -3
else
  echo -e "  TLP Status: ${RED}✗ Not running${NC}"
  echo -e "  ${YELLOW}→ Run: sudo systemctl start tlp${NC}"
fi

# ============================================================
# 6. BATTERY DRAIN ESTIMATE
# ============================================================
echo -e "\n${BOLD}[6] ESTIMATED BATTERY LIFE${NC}"

BAT_POWER=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null)
BAT_ENERGY=$(cat /sys/class/power_supply/BAT0/energy_now 2>/dev/null)

if [[ -n "$BAT_POWER" && -n "$BAT_ENERGY" ]]; then
  POWER_WATTS=$(echo "scale=2; $BAT_POWER / 1000000" | bc)
  ENERGY_WH=$(echo "scale=1; $BAT_ENERGY / 1000000" | bc)

  if (( $(echo "$POWER_WATTS > 0" | bc -l) )); then
    HOURS=$(echo "scale=1; $ENERGY_WH / $POWER_WATTS" | bc)
    echo -e "  Current Draw: ${YELLOW}${POWER_WATTS}W${NC}"
    echo -e "  Energy Remaining: ${ENERGY_WH}Wh"
    echo -e "  Estimated Time: ${CYAN}${HOURS}h${NC}"

    if [[ "$ACTIVE_PROFILE" == "gaming" ]] && is_on_battery; then
      echo -e "  Status: ${RED}✗ Gaming on battery — plug in AC adapter${NC}"
    elif (( $(echo "$POWER_WATTS < 8" | bc -l) )); then
      echo -e "  Status: ${GREEN}✓ Good optimization${NC}"
    elif (( $(echo "$POWER_WATTS < 12" | bc -l) )); then
      echo -e "  Status: ${YELLOW}⚠ Moderate (can improve)${NC}"
    else
      echo -e "  Status: ${RED}✗ High drain${NC}"
    fi
  fi
fi

# ============================================================
# 7. POWER-HUNGRY PROCESSES
# ============================================================
echo -e "\n${BOLD}[7] TOP POWER CONSUMERS${NC}"

if command -v powertop &>/dev/null; then
  echo -e "  ${CYAN}Running PowerTOP (10 seconds)...${NC}"
  if [[ $EUID -eq 0 ]]; then
    powertop -r 10 -b 2>/dev/null | grep -A 5 "Top 10 Power" || true
  else
    sudo powertop -r 10 -b 2>/dev/null | grep -A 5 "Top 10 Power" || true
  fi
else
  echo -e "  ${YELLOW}PowerTOP not installed${NC}"
fi

echo -e "\n${CYAN}═══════════════════════════════════════════════════════${NC}\n"

# ============================================================
# RECOMMENDATIONS
# ============================================================
echo -e "${BOLD}RECOMMENDATIONS:${NC}\n"

if [[ ! -f /etc/tlp.conf ]]; then
  echo -e "  • ${RED}TLP not configured${NC} → ${CYAN}sudo bash ubuntu-battery-optimizer.sh${NC}"
fi

if [[ -z "$ACTIVE_PROFILE" ]]; then
  echo -e "  • ${RED}No profile active${NC} → ${CYAN}sudo bash ubuntu-battery-optimizer.sh${NC}"
fi

PRIME=$(prime-select query 2>/dev/null)
if [[ -n "$PRIME" && -n "$EXPECTED_PRIME" && "$PRIME" != "$EXPECTED_PRIME" ]]; then
  echo -e "  • ${RED}GPU mode mismatch${NC} (got ${PRIME}, want ${EXPECTED_PRIME})"
  echo -e "    → ${CYAN}sudo bash ubuntu-battery-optimizer.sh --mode ${ACTIVE_PROFILE:-balanced} && sudo reboot${NC}"
fi

if [[ "$ACTIVE_PROFILE" == "gaming" ]] && is_on_battery; then
  echo -e "  • ${RED}Gaming profile on battery${NC} → Plug in AC adapter"
fi

POWER=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null)
if [[ -n "$POWER" ]]; then
  POWER_WATTS=$(echo "scale=1; $POWER / 1000000" | bc)
  if (( $(echo "$POWER_WATTS > 12" | bc -l) )) && [[ "$ACTIVE_PROFILE" != "gaming" ]]; then
    echo -e "  • ${RED}High power draw${NC} → Check BIOS Graphics Mode = Integrated Only"
  fi
fi

echo -e "\nGuides: ${CYAN}docs/STEAM-GAMING-GUIDE.md${NC} (gaming) | ${CYAN}../ubuntu+nvidia/NVIDIA-GPU-BATTERY-GUIDE.md${NC}\n"
