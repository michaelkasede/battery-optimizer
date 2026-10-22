# shellcheck shell=bash
# Renderers: produce file contents on stdout from CONF, detection results and
# install options. Pure functions — they never touch the filesystem except to
# read templates.

AUTO_SWITCH=${AUTO_SWITCH:-1}

# render_template FILE NAME=VALUE... — replace @NAME@ placeholders
render_template() {
  local file="$1" content kv name value
  shift
  content=$(<"$file")
  for kv in "$@"; do
    name="${kv%%=*}"
    value="${kv#*=}"
    # quoted replacement: no '&' expansion (bash 5.2 patsub_replacement)
    content="${content//@"$name"@/"$value"}"
  done
  if [[ "$content" =~ @[A-Z_]+@ ]]; then
    err "unrendered placeholder ${BASH_REMATCH[0]} in $file"
    return 1
  fi
  printf '%s\n' "$content"
}

# map_platform_profile WANTED — closest value from PP_CHOICES, empty if none
map_platform_profile() {
  local want="$1" c candidates
  case "$want" in
    low-power)   candidates="low-power quiet cool" ;;
    performance) candidates="performance balanced-performance" ;;
    *)           candidates="$want" ;;
  esac
  for c in $candidates; do
    [[ " $PP_CHOICES " == *" $c "* ]] && { printf '%s' "$c"; return 0; }
  done
  return 0
}

# usb_denylist — configured denylist plus detected receivers, de-duplicated
usb_denylist() {
  local id out=""
  for id in $(conf_get USB_DENYLIST) "${USB_RECEIVERS[@]}"; do
    [[ " $out " == *" $id "* ]] || out+=" $id"
  done
  printf '%s' "${out# }"
}

render_tlp_dropin() {
  local key val mapped bat start stop
  start=$(conf_get CHARGE_START 40)
  stop=$(conf_get CHARGE_STOP 80)

  cat <<EOF
# Installed by battery-optimizer $BO_VERSION — removed by: battery-optimizer uninstall
# Generated from config/profiles.conf; edits are overwritten on reinstall.
#
# GNOME Power Mode -> TLP profile -> suffix:
#   Performance -> performance -> _ON_AC
#   Balanced    -> balanced    -> _ON_BAT
#   Power Saver -> power-saver -> _ON_SAV (falls back to _ON_BAT where TLP
#                                          has no _ON_SAV variant)

# 0 = never switch, 1 = Performance on AC / Balanced on battery,
# 2 = smart (keep a manually chosen profile across plug/unplug)
TLP_AUTO_SWITCH=$AUTO_SWITCH
TLP_DEFAULT_MODE=BAL
TLP_PERSISTENT_DEFAULT=0

EOF

  for key in "${CONF_KEYS[@]}"; do
    val="${CONF[$key]}"
    case "$key" in
      HOOK_*|CHARGE_*|USB_DENYLIST) continue ;;
      PLATFORM_PROFILE_ON_*)
        [[ -n "$PP_CHOICES" ]] || continue
        mapped=$(map_platform_profile "$val")
        [[ -n "$mapped" ]] || continue
        val="$mapped"
        ;;
      MEM_SLEEP_ON_*)
        mem_sleep_supports "$val" || continue
        ;;
    esac
    if [[ "$val" == *" "* || -z "$val" ]]; then
      printf '%s="%s"\n' "$key" "$val"
    else
      printf '%s=%s\n' "$key" "$val"
    fi
  done

  printf 'USB_DENYLIST="%s"\n' "$(usb_denylist)"

  local any=0
  for bat in "${BATTERIES[@]}"; do
    [[ "$bat" == BAT0 || "$bat" == BAT1 ]] || continue
    if (( ${BAT_START[$bat]:-0} || ${BAT_STOP[$bat]:-0} )); then
      (( any )) || printf '\n# Battery care: charge thresholds\n'
      any=1
      (( ${BAT_START[$bat]:-0} )) && printf 'START_CHARGE_THRESH_%s=%s\n' "$bat" "$start"
      (( ${BAT_STOP[$bat]:-0} )) && printf 'STOP_CHARGE_THRESH_%s=%s\n' "$bat" "$stop"
    fi
  done
  return 0
}

render_hook_conf() {
  local igpu_pci=""
  [[ "$IGPU_DRIVER" == i915 ]] && igpu_pci="$IGPU_PCI"
  cat <<EOF
# Installed by battery-optimizer $BO_VERSION — removed by: battery-optimizer uninstall
# Power Saver extras applied by battery-optimizer-hook.service.
# Parsed as KEY=VALUE against an allow-list; never sourced.
HOOK_BRIGHTNESS_CAP_PCT=$(conf_get HOOK_BRIGHTNESS_CAP_PCT 0)
HOOK_DOCKER=$(conf_get HOOK_DOCKER ignore)
HOOK_IGPU_MAX_PCT=$(conf_get HOOK_IGPU_MAX_PCT 100)
HOOK_BACKLIGHT=$BACKLIGHT
HOOK_IGPU_PCI=$igpu_pci
EOF
}

render_hook_unit() {
  render_template "$BO_HOME/templates/battery-optimizer-hook.service" \
    "VERSION=$BO_VERSION" "LIBDIR=$LIB_INSTALL_DIR" "HOOK_CONF=$HOOK_CONF"
}

render_udev_rules() {
  render_template "$BO_HOME/templates/udev-power.rules" \
    "VERSION=$BO_VERSION" "HOOK_UNIT_NAME=$HOOK_UNIT_NAME"
  if [[ "$DGPU_VENDOR" == nvidia ]]; then
    render_template "$BO_HOME/templates/udev-nvidia-pm.rules"
  fi
}

render_nvidia_modprobe() {
  render_template "$BO_HOME/templates/nvidia-modprobe.conf" "VERSION=$BO_VERSION"
  if nvidia_supports_rtd3; then
    printf '%s\n' "# Turing or newer: fine-grained runtime D3 (dGPU off when idle)" \
      "options nvidia NVreg_DynamicPowerManagement=0x02"
  else
    printf '%s\n' "# Pre-Turing GPU: NVreg_DynamicPowerManagement=0x02 is unsupported"
  fi
}
