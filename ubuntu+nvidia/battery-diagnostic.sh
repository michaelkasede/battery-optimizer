#!/bin/bash
# ============================================================
# Battery Health & GPU Power Diagnostic
# For ThinkPad P14s Gen 3
# Run: bash battery-diagnostic.sh
# ============================================================

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Battery & Power Diagnostic - ThinkPad P14s Gen 3${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}\n"

# ============================================================
# 1. BATTERY STATUS
# ============================================================
echo -e "${BOLD}[1] BATTERY STATUS${NC}"
if command -v acpi &>/dev/null; then
  acpi -b
  echo ""
  
  # Get detailed battery info
  BAT_PATH="/sys/class/power_supply/BAT0"
  if [ -d "$BAT_PATH" ]; then
    CURRENT=$(cat "$BAT_PATH/power_now" 2>/dev/null)
    CAPACITY=$(cat "$BAT_PATH/capacity" 2>/dev/null)
    STATUS=$(cat "$BAT_PATH/status" 2>/dev/null)
    ENERGY_NOW=$(cat "$BAT_PATH/energy_now" 2>/dev/null)
    ENERGY_FULL=$(cat "$BAT_PATH/energy_full" 2>/dev/null)
    ENERGY_FULL_DESIGN=$(cat "$BAT_PATH/energy_full_design" 2>/dev/null)
    
    echo -e "  Current Power Draw: ${CYAN}$(echo "scale=2; $CURRENT/1000000" | bc)W${NC}"
    echo -e "  Battery Capacity: ${YELLOW}$CAPACITY%${NC}"
    echo -e "  Status: $STATUS"
    
    # Health check
    if [ ! -z "$ENERGY_FULL" ] && [ ! -z "$ENERGY_FULL_DESIGN" ]; then
      HEALTH=$(echo "scale=1; $ENERGY_FULL * 100 / $ENERGY_FULL_DESIGN" | bc)
      if (( $(echo "$HEALTH < 80" | bc -l) )); then
        echo -e "  Battery Health: ${RED}$HEALTH% (degraded)${NC}"
      else
        echo -e "  Battery Health: ${GREEN}$HEALTH% (good)${NC}"
      fi
    fi
  fi
fi

# ============================================================
# 2. NVIDIA GPU STATUS
# ============================================================
echo -e "\n${BOLD}[2] NVIDIA GPU STATUS${NC}"

if command -v nvidia-smi &>/dev/null; then
  nvidia-smi --query-gpu=index,name,driver_version,power.draw,power.limit,utilization.gpu,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null | while IFS=',' read -r idx name driver pwr limit util temp; do
    echo -e "  GPU: ${CYAN}$name${NC}"
    echo -e "    Driver: $driver"
    echo -e "    Power Draw: ${pwr}W / ${limit}W"
    echo -e "    Utilization: ${util}%"
    echo -e "    Temperature: ${temp}°C"
  done
  
  # Check if GPU is actually sleeping
  echo ""
  PWR=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits)
  if (( $(echo "$PWR < 1" | bc -l) )); then
    echo -e "  GPU State: ${GREEN}✓ Sleeping (< 1W)${NC}"
  elif (( $(echo "$PWR < 5" | bc -l) )); then
    echo -e "  GPU State: ${YELLOW}⚠ Low power (1-5W)${NC}"
  else
    echo -e "  GPU State: ${RED}✗ Active (>5W) - Check prime-select${NC}"
  fi
  
  # Check prime mode
  if command -v prime-select &>/dev/null; then
    MODE=$(prime-select query 2>/dev/null)
    echo -e "  Prime Mode: ${CYAN}$MODE${NC}"
    if [ "$MODE" != "on-demand" ]; then
      echo -e "    ${RED}→ Run: sudo prime-select on-demand${NC}"
    fi
  fi
else
  echo -e "  ${YELLOW}NVIDIA drivers not installed${NC}"
fi

# ============================================================
# 3. DISPLAY BRIGHTNESS
# ============================================================
echo -e "\n${BOLD}[3] DISPLAY (1920×1200 IPS)${NC}"

BRIGHTNESS_PATH="/sys/class/backlight"
if [ -d "$BRIGHTNESS_PATH" ]; then
  for device in "$BRIGHTNESS_PATH"/*; do
    if [ -d "$device" ]; then
      DEV=$(basename "$device")
      CURRENT=$(cat "$device/brightness" 2>/dev/null)
      MAX=$(cat "$device/max_brightness" 2>/dev/null)
      PCT=$((CURRENT * 100 / MAX))
      echo -e "  $DEV: ${CYAN}$PCT%${NC} ($CURRENT / $MAX)"
    fi
  done
  echo -e "  ${YELLOW}Tip: Set to 30-40% on battery to save 2-3W${NC}"
fi

# ============================================================
# 4. CPU FREQUENCY SCALING
# ============================================================
echo -e "\n${BOLD}[4] CPU FREQUENCY SCALING${NC}"

if [ -d "/sys/devices/system/cpu/cpu0/cpufreq" ]; then
  GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
  FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq 2>/dev/null)
  FREQ_MHZ=$((FREQ / 1000))
  
  echo -e "  Governor: ${CYAN}$GOVERNOR${NC}"
  echo -e "  Current Frequency: ${FREQ_MHZ}MHz"
  
  if [ "$GOVERNOR" == "powersave" ]; then
    echo -e "  Status: ${GREEN}✓ Powersave (battery optimized)${NC}"
  elif [ "$GOVERNOR" == "performance" ]; then
    echo -e "  Status: ${RED}✗ Performance (high power)${NC}"
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

if [ ! -z "$BAT_POWER" ] && [ ! -z "$BAT_ENERGY" ]; then
  POWER_WATTS=$(echo "scale=2; $BAT_POWER / 1000000" | bc)
  ENERGY_WH=$(echo "scale=1; $BAT_ENERGY / 1000000" | bc)
  
  # Calculate hours remaining
  if (( $(echo "$POWER_WATTS > 0" | bc -l) )); then
    HOURS=$(echo "scale=1; $ENERGY_WH / $POWER_WATTS" | bc)
    echo -e "  Current Draw: ${YELLOW}${POWER_WATTS}W${NC}"
    echo -e "  Energy Remaining: ${ENERGY_WH}Wh"
    echo -e "  Estimated Time: ${CYAN}${HOURS}h${NC}"
    
    if (( $(echo "$POWER_WATTS < 8" | bc -l) )); then
      echo -e "  Status: ${GREEN}✓ Good optimization${NC}"
    elif (( $(echo "$POWER_WATTS < 12" | bc -l) )); then
      echo -e "  Status: ${YELLOW}⚠ Moderate (can improve)${NC}"
    else
      echo -e "  Status: ${RED}✗ High drain (run optimizer)${NC}"
    fi
  fi
fi

# ============================================================
# 7. POWER-HUNGRY PROCESSES
# ============================================================
echo -e "\n${BOLD}[7] TOP POWER CONSUMERS${NC}"

if command -v powertop &>/dev/null; then
  echo -e "  ${CYAN}Running PowerTOP (this takes 10 seconds)...${NC}"
  sudo powertop -r 10 -b 2>/dev/null | grep -A 5 "Top 10 Power"
else
  echo -e "  ${YELLOW}PowerTOP not installed (run optimizer first)${NC}"
fi

echo -e "\n${CYAN}═══════════════════════════════════════════════════════${NC}\n"

# ============================================================
# SUMMARY & RECOMMENDATIONS
# ============================================================
echo -e "${BOLD}RECOMMENDATIONS:${NC}\n"

if [ ! -f "/etc/tlp.conf" ]; then
  echo -e "  1. ${RED}✗ TLP not configured${NC} → Run: ${CYAN}sudo bash ubuntu-battery-optimizer.sh${NC}"
fi

MODE=$(prime-select query 2>/dev/null)
if [ "$MODE" != "on-demand" ] && [ ! -z "$MODE" ]; then
  echo -e "  2. ${RED}✗ NVIDIA not in on-demand${NC} → Run: ${CYAN}sudo prime-select on-demand${NC}"
fi

BRIGHTNESS_PCT=$(cat /sys/class/backlight/*/brightness 2>/dev/null | head -1)
if [ ! -z "$BRIGHTNESS_PCT" ] && [ "$BRIGHTNESS_PCT" -gt "150" ]; then
  echo -e "  3. ${YELLOW}⚠ Display brightness too high${NC} → Set to 30-40% on battery"
fi

POWER=$(cat /sys/class/power_supply/BAT0/power_now 2>/dev/null)
POWER_WATTS=$(echo "scale=1; $POWER / 1000000" | bc)
if (( $(echo "$POWER_WATTS > 12" | bc -l) )); then
  echo -e "  4. ${RED}✗ Power draw still high${NC} → Check BIOS Graphics Mode = Integrated Only"
fi

echo -e "\nFor detailed guidance, see: ${CYAN}NVIDIA-GPU-BATTERY-GUIDE.md${NC}\n"
