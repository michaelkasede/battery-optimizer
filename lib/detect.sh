# shellcheck shell=bash
# Hardware and platform detection. Reads sysfs/procfs only (lspci is used for
# display names when available), so it can run against fixture trees.

OS_ID=""; OS_VERSION_ID=""; OS_PRETTY=""
CPU_VENDOR=""
IGPU_PCI=""; IGPU_VENDOR=""; IGPU_DRIVER=""; IGPU_NAME=""
DGPU_PCI=""; DGPU_VENDOR=""; DGPU_DRIVER=""; DGPU_NAME=""
DGPU_CLASS=""; DGPU_DEVICE_ID=""
declare -ga BATTERIES=()
declare -gA BAT_START=() BAT_STOP=()
AC_PRESENT=0
BACKLIGHT=""
PP_CHOICES=""
MEM_SLEEP_MODES=""
declare -ga USB_RECEIVERS=() USB_RECEIVER_NAMES=()

pci_vendor_name() {
  case "$1" in
    0x8086) printf intel ;;
    0x10de) printf nvidia ;;
    0x1002) printf amd ;;
    *)      printf 'other(%s)' "$1" ;;
  esac
}

pci_driver() {
  local link="$1/driver"
  [[ -L "$link" ]] && basename "$(readlink "$link")"
  return 0
}

pci_display_name() {
  have lspci || return 0
  lspci -s "$1" 2>/dev/null | sed -E 's/^[^ ]+ [^:]+: //' | head -1 || true
}

# GPU drives an internal panel (eDP/LVDS/DSI connector exists)?
gpu_has_internal_panel() {
  local c
  for c in "$1"/drm/card*/card*-eDP-* "$1"/drm/card*/card*-LVDS-* "$1"/drm/card*/card*-DSI-*; do
    [[ -e "$c" ]] && return 0
  done
  return 1
}

detect_os() {
  local f line
  f=$(p /etc/os-release)
  OS_ID=""; OS_VERSION_ID=""; OS_PRETTY=""
  [[ -r "$f" ]] || return 0
  while IFS= read -r line; do
    case "$line" in
      ID=*)          OS_ID="${line#ID=}"; OS_ID="${OS_ID//\"/}" ;;
      VERSION_ID=*)  OS_VERSION_ID="${line#VERSION_ID=}"; OS_VERSION_ID="${OS_VERSION_ID//\"/}" ;;
      PRETTY_NAME=*) OS_PRETTY="${line#PRETTY_NAME=}"; OS_PRETTY="${OS_PRETTY//\"/}" ;;
    esac
  done < "$f"
}

detect_cpu() {
  CPU_VENDOR=""
  local line
  [[ -r "$PROC/cpuinfo" ]] || return 0
  while IFS= read -r line; do
    if [[ "$line" == vendor_id* ]]; then
      case "$line" in
        *GenuineIntel*) CPU_VENDOR=intel ;;
        *AuthenticAMD*) CPU_VENDOR=amd ;;
        *)              CPU_VENDOR=other ;;
      esac
      break
    fi
  done < "$PROC/cpuinfo"
}

detect_gpus() {
  IGPU_PCI=""; IGPU_VENDOR=""; IGPU_DRIVER=""; IGPU_NAME=""
  DGPU_PCI=""; DGPU_VENDOR=""; DGPU_DRIVER=""; DGPU_NAME=""
  DGPU_CLASS=""; DGPU_DEVICE_ID=""

  local dev cls vendor bdf gpus=() internal="" bootvga="" intel=""
  for dev in "$SYS"/bus/pci/devices/*; do
    [[ -r "$dev/class" ]] || continue
    cls=$(read_sys "$dev/class")
    case "$cls" in 0x0300*|0x0302*|0x0380*) ;; *) continue ;; esac
    bdf=$(basename "$dev")
    gpus+=("$bdf")
    vendor=$(read_sys "$dev/vendor")
    [[ "$vendor" == 0x10de ]] && continue   # NVIDIA is never the iGPU on x86 laptops
    if [[ -z "$internal" ]] && gpu_has_internal_panel "$dev"; then internal="$bdf"; fi
    if [[ -z "$bootvga" && "$(read_sys "$dev/boot_vga")" == 1 ]]; then bootvga="$bdf"; fi
    if [[ -z "$intel" && "$vendor" == 0x8086 ]]; then intel="$bdf"; fi
  done

  # iGPU: the one driving the internal panel, else boot VGA, else Intel
  IGPU_PCI="${internal:-${bootvga:-$intel}}"
  if [[ -z "$IGPU_PCI" && ${#gpus[@]} -eq 1 ]]; then
    # a single non-NVIDIA GPU is the integrated one
    [[ "$(read_sys "$SYS/bus/pci/devices/${gpus[0]}/vendor")" != 0x10de ]] && IGPU_PCI="${gpus[0]}"
  fi

  for bdf in "${gpus[@]}"; do
    [[ "$bdf" == "$IGPU_PCI" ]] && continue
    DGPU_PCI="$bdf"
    break
  done

  if [[ -n "$IGPU_PCI" ]]; then
    dev="$SYS/bus/pci/devices/$IGPU_PCI"
    IGPU_VENDOR=$(pci_vendor_name "$(read_sys "$dev/vendor")")
    IGPU_DRIVER=$(pci_driver "$dev")
    IGPU_NAME=$(pci_display_name "$IGPU_PCI")
  fi
  if [[ -n "$DGPU_PCI" ]]; then
    dev="$SYS/bus/pci/devices/$DGPU_PCI"
    DGPU_VENDOR=$(pci_vendor_name "$(read_sys "$dev/vendor")")
    DGPU_DRIVER=$(pci_driver "$dev")
    DGPU_NAME=$(pci_display_name "$DGPU_PCI")
    DGPU_DEVICE_ID=$(read_sys "$dev/device")
    cls=$(read_sys "$dev/class")
    DGPU_CLASS="${cls:2:4}"
  fi
}

# NVIDIA fine-grained dynamic power management (NVreg_DynamicPowerManagement
# =0x02) needs Turing or newer. Turing starts at device ID 0x1e00.
nvidia_supports_rtd3() {
  [[ "$DGPU_VENDOR" == nvidia && -n "$DGPU_DEVICE_ID" ]] || return 1
  (( DGPU_DEVICE_ID >= 0x1e00 ))
}

dgpu_has_outputs() { [[ "$DGPU_CLASS" == 0300 ]]; }

detect_power_supplies() {
  BATTERIES=(); BAT_START=(); BAT_STOP=(); AC_PRESENT=0
  local ps name type scope
  for ps in "$SYS"/class/power_supply/*; do
    [[ -d "$ps" ]] || continue
    name=$(basename "$ps")
    type=$(read_sys "$ps/type")
    scope=$(read_sys "$ps/scope")
    case "$type" in
      Mains) AC_PRESENT=1 ;;
      Battery)
        [[ "$scope" == Device ]] && continue   # mouse/keyboard batteries
        [[ "$name" =~ ^BAT[0-9]$ ]] || continue
        BATTERIES+=("$name")
        BAT_START[$name]=0; BAT_STOP[$name]=0
        if [[ -e "$ps/charge_control_start_threshold" || -e "$ps/charge_start_threshold" ]]; then
          BAT_START[$name]=1
        fi
        if [[ -e "$ps/charge_control_end_threshold" || -e "$ps/charge_stop_threshold" ]]; then
          BAT_STOP[$name]=1
        fi
        ;;
    esac
  done
}

detect_backlight() {
  BACKLIGHT=""
  local bl type target score best=-1 name
  for bl in "$SYS"/class/backlight/*; do
    [[ -e "$bl/brightness" && -e "$bl/max_brightness" ]] || continue
    name=$(basename "$bl")
    type=$(read_sys "$bl/type")
    target=""
    [[ -e "$bl/device" ]] && target=$(basename "$(readlink -f "$bl/device")")
    case "$type" in
      raw)      score=1; [[ "$target" =~ -(eDP|LVDS|DSI)- ]] && score=4 ;;
      firmware) score=3 ;;
      platform) score=2 ;;
      *)        score=0 ;;
    esac
    if (( score > best )); then best=$score; BACKLIGHT="$name"; fi
  done
}

detect_platform_profile() {
  PP_CHOICES=$(read_sys "$SYS/firmware/acpi/platform_profile_choices")
}

detect_mem_sleep() {
  MEM_SLEEP_MODES=$(read_sys "$SYS/power/mem_sleep")
}

mem_sleep_supports() {
  [[ " ${MEM_SLEEP_MODES//[\[\]]/} " == *" $1 "* ]]
}

# Known USB HID receivers that must never autosuspend (input lag)
USB_RECEIVER_IDS="046d:c52b 046d:c52f 046d:c532 046d:c534 046d:c539 046d:c53a 046d:c53f 046d:c545 046d:c547 046d:c548"

detect_usb_receivers() {
  USB_RECEIVERS=(); USB_RECEIVER_NAMES=()
  local dev id product
  for dev in "$SYS"/bus/usb/devices/*; do
    [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
    id="$(read_sys "$dev/idVendor"):$(read_sys "$dev/idProduct")"
    product=$(read_sys "$dev/product")
    if [[ " $USB_RECEIVER_IDS " == *" $id "* || "${product,,}" == *receiver* ]]; then
      [[ "$id" =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || continue
      [[ " ${USB_RECEIVERS[*]} " == *" $id "* ]] && continue
      USB_RECEIVERS+=("$id")
      USB_RECEIVER_NAMES+=("${product:-unknown}")
    fi
  done
}

detect_all() {
  detect_os
  detect_cpu
  detect_gpus
  detect_power_supplies
  detect_backlight
  detect_platform_profile
  detect_mem_sleep
  detect_usb_receivers
}

# platform_supported — prints reasons and fails if the machine is out of scope
platform_supported() {
  local rc=0
  if [[ "$OS_ID" != ubuntu || "$OS_VERSION_ID" != 24.04 ]]; then
    err "Unsupported OS: ${OS_PRETTY:-unknown} (Ubuntu 24.04.x required)"; rc=1
  fi
  if [[ -z "$DGPU_PCI" ]]; then
    err "No discrete GPU found (this project targets iGPU + dGPU laptops)"; rc=1
  fi
  if (( ${#BATTERIES[@]} == 0 )); then
    err "No system battery found"; rc=1
  fi
  return $rc
}

# Boot parameters that weaken isolation or are no-ops on stock Ubuntu kernels.
# status only warns about these; nothing ever changes them.
WEAK_BOOT_PARAMS=(
  "vfio_iommu_type1.allow_unsafe_interrupts|weakens IOMMU interrupt isolation"
  "pcie_acs_override|no effect on Ubuntu's stock kernel (needs the ACS override patch)"
  "kvm.ignore_msrs|hides guest MSR errors; only needed for some VMs"
  "iommu=pt|IOMMU passthrough mode (VFIO leftover?)"
  "intel_iommu=on|VFIO/IOMMU leftover?"
)

# weak_boot_param_warnings CMDLINE — print "param: reason" lines
weak_boot_param_warnings() {
  local cmdline=" $1 " entry key reason
  for entry in "${WEAK_BOOT_PARAMS[@]}"; do
    key="${entry%%|*}"; reason="${entry#*|}"
    if [[ "$cmdline" == *" $key"[=\ ]* ]]; then
      printf '%s: %s\n' "$key" "$reason"
    fi
  done
}
