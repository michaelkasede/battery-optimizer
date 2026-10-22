# shellcheck shell=bash
# Shared bats helpers: fixture sysfs trees, a fake root filesystem and command
# stubs that record calls and keep a fake dpkg/systemd state.

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
CLI="$REPO/battery-optimizer"

setup_env() {
  TMP="$BATS_TEST_TMPDIR"
  export BO_ROOT="$TMP/root"
  export BO_SYSFS="$TMP/sys"
  export BO_PROC="$TMP/proc"
  export BO_TEST_LOG="$TMP/calls.log"
  mkdir -p "$BO_ROOT" "$BO_SYSFS" "$BO_PROC"
  : > "$BO_TEST_LOG"

  mkdir -p "$TMP/bin"
  local c
  for c in apt-get add-apt-repository dpkg-query systemctl prime-select modinfo \
           udevadm update-initramfs update-grub tlp tlpctl lspci gdbus; do
    ln -sf "$REPO/tests/stubs/stub" "$TMP/bin/$c"
  done
  export PATH="$TMP/bin:$PATH"
}

# lib_env — source the libraries into the test shell
lib_env() {
  BO_HOME="$REPO"
  BO_VERSION="$(<"$REPO/VERSION")"
  # shellcheck source=../lib/common.sh
  source "$REPO/lib/common.sh"
  source "$REPO/lib/config.sh"
  source "$REPO/lib/detect.sh"
  source "$REPO/lib/render.sh"
  source "$REPO/lib/manifest.sh"
  source "$REPO/lib/migrate.sh"
  source "$REPO/lib/system.sh"
}

w() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }

# pci BDF CLASS VENDOR DEVICE DRIVER [BOOT_VGA]
pci() {
  local d="$BO_SYSFS/bus/pci/devices/$1"
  mkdir -p "$d/power" "$BO_SYSFS/bus/pci/drivers/$5"
  w "$d/class" "$2"; w "$d/vendor" "$3"; w "$d/device" "$4"
  w "$d/power/control" auto; w "$d/power/runtime_status" suspended
  [[ -n "${6:-}" ]] && w "$d/boot_vga" "$6"
  ln -sfn "../../../bus/pci/drivers/$5" "$d/driver"
}

# connector BDF CARD NAME — DRM connector under a GPU
connector() { mkdir -p "$BO_SYSFS/bus/pci/devices/$1/drm/$2/$2-$3"; }

# i915_freq BDF CARD — i915 frequency files
i915_freq() {
  local c="$BO_SYSFS/bus/pci/devices/$1/drm/$2"
  mkdir -p "$c"
  w "$c/gt_RP0_freq_mhz" 1450; w "$c/gt_RPn_freq_mhz" 100
  w "$c/gt_max_freq_mhz" 1450; w "$c/gt_boost_freq_mhz" 1450
}

# battery NAME THRESHOLDS(both|stop|none) [STATUS]
battery() {
  local b="$BO_SYSFS/class/power_supply/$1"
  w "$b/type" Battery; w "$b/scope" System; w "$b/status" "${3:-Discharging}"
  w "$b/capacity" 83; w "$b/power_now" 7500000
  w "$b/energy_full" 50000000; w "$b/energy_now" 41500000
  case "$2" in
    both) w "$b/charge_control_start_threshold" 0; w "$b/charge_control_end_threshold" 100 ;;
    stop) w "$b/charge_control_end_threshold" 100 ;;
  esac
}

ac() { w "$BO_SYSFS/class/power_supply/AC/type" Mains; w "$BO_SYSFS/class/power_supply/AC/online" 0; }

# backlight NAME TYPE [DEVICE_TARGET]
backlight() {
  local b="$BO_SYSFS/class/backlight/$1"
  w "$b/type" "$2"; w "$b/max_brightness" 19393; w "$b/brightness" 15000
  if [[ -n "${3:-}" ]]; then mkdir -p "$BO_SYSFS/$3"; ln -sfn "$BO_SYSFS/$3" "$b/device"; fi
}

usb() {
  local d="$BO_SYSFS/bus/usb/devices/$1"
  w "$d/idVendor" "$2"; w "$d/idProduct" "$3"; w "$d/product" "$4"
}

cpu() { w "$BO_PROC/cpuinfo" "vendor_id	: $1"; }

os_release() {
  w "$BO_ROOT/etc/os-release" 'PRETTY_NAME="Ubuntu 24.04.5 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
ID=ubuntu'
}

# Reference machine: ThinkPad P14s Gen 3 (Intel Iris Xe + NVIDIA T550)
fixture_p14s() {
  cpu GenuineIntel
  pci 0000:00:02.0 0x030000 0x8086 0x46a6 i915 1
  connector 0000:00:02.0 card1 eDP-1
  connector 0000:00:02.0 card1 HDMI-A-1
  i915_freq 0000:00:02.0 card1
  pci 0000:03:00.0 0x030200 0x10de 0x1fb7 nvidia
  battery BAT0 both
  ac
  backlight intel_backlight raw "bus/pci/devices/0000:00:02.0/drm/card1/card1-eDP-1"
  usb 3-2 046d c548 "USB Receiver"
  usb 3-4 174f 1812 "Integrated Camera"
  w "$BO_SYSFS/firmware/acpi/platform_profile_choices" "low-power balanced performance"
  w "$BO_SYSFS/power/mem_sleep" "s2idle [deep]"
  w "$BO_PROC/cmdline" "BOOT_IMAGE=/boot/vmlinuz root=UUID=x ro quiet splash iommu=pt intel_iommu=on i915.enable_gvt=1 kvm.ignore_msrs=1 pcie_acs_override=downstream,multifunction vfio_iommu_type1.allow_unsafe_interrupts=1 nmi_watchdog=0 mem_sleep_default=deep i915.enable_psr=2 i915.enable_fbc=1 pcie_aspm=force"
  os_release
}

# Ryzen laptop: AMD iGPU (not on bus 0) + AMD dGPU, BAT1, stop threshold only
fixture_amd() {
  cpu AuthenticAMD
  pci 0000:03:00.0 0x030000 0x1002 0x73ef amdgpu
  pci 0000:05:00.0 0x030000 0x1002 0x1681 amdgpu 1
  connector 0000:05:00.0 card1 eDP-1
  connector 0000:03:00.0 card0 DP-1
  battery BAT1 stop
  ac
  backlight amdgpu_bl1 raw "bus/pci/devices/0000:05:00.0/drm/card1/card1-eDP-1"
  w "$BO_SYSFS/firmware/acpi/platform_profile_choices" "quiet balanced performance"
  w "$BO_SYSFS/power/mem_sleep" "[s2idle]"
  os_release
}

# Gaming laptop: Intel iGPU + NVIDIA Ampere with outputs, no thresholds,
# no platform profile, firmware + raw backlight
fixture_nvidia_outputs() {
  cpu GenuineIntel
  pci 0000:00:02.0 0x030000 0x8086 0x9a49 i915 1
  connector 0000:00:02.0 card0 eDP-1
  pci 0000:01:00.0 0x030000 0x10de 0x2560 nvidia
  battery BAT0 none
  ac
  backlight acpi_video0 firmware
  backlight intel_backlight raw
  w "$BO_SYSFS/power/mem_sleep" "[s2idle]"
  os_release
}

# fake_pkgs PKG... — mark packages as installed in the stub dpkg database
fake_pkgs() {
  mkdir -p "$BO_ROOT/var/lib/stub"
  local p
  for p in "$@"; do printf '%s 1.0\n' "$p" >> "$BO_ROOT/var/lib/stub/pkgs"; done
}

# fake_units UNIT=STATE... — systemd unit enablement states in the stub
fake_units() {
  mkdir -p "$BO_ROOT/var/lib/stub"
  local u
  for u in "$@"; do printf '%s %s\n' "${u%%=*}" "${u#*=}" >> "$BO_ROOT/var/lib/stub/units"; done
}

# Stock Ubuntu 24.04 desktop state
fake_stock_system() {
  fake_pkgs power-profiles-daemon python3-gi thermald nvidia-prime
  fake_units power-profiles-daemon.service=enabled thermald.service=enabled \
             nvidia-suspend.service=enabled nvidia-resume.service=enabled \
             nvidia-hibernate.service=enabled
  w "$BO_ROOT/etc/default/grub" 'GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""'
  mkdir -p "$BO_ROOT/etc/apt/sources.list.d" "$BO_ROOT/etc/modprobe.d"
  echo on-demand > "$BO_ROOT/var/lib/stub/prime"
  sort -o "$BO_ROOT/var/lib/stub/pkgs" "$BO_ROOT/var/lib/stub/pkgs"
  sort -o "$BO_ROOT/var/lib/stub/units" "$BO_ROOT/var/lib/stub/units"
}

# v1.1 leftovers as found on the reference machine
fake_v11_artifacts() {
  w "$BO_ROOT/etc/default/grub" 'GRUB_DEFAULT=0
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu=pt intel_iommu=on i915.enable_gvt=1 kvm.ignore_msrs=1 pcie_acs_override=downstream,multifunction vfio_iommu_type1.allow_unsafe_interrupts=1 nmi_watchdog=0 mem_sleep_default=deep i915.enable_psr=2 i915.enable_fbc=1 i915.enable_rc6=7 nvme_core.default_ps_max_latency_us=5500 intel_idle.max_cstate=9 usbcore.autosuspend=5 pcie_aspm=force"
GRUB_CMDLINE_LINUX=""'
  w "$BO_ROOT/etc/modprobe.d/i915-power.conf" '# Intel Iris Xe - Profile: Balanced
options i915 enable_psr=2
options i915 enable_fbc=1'
  w "$BO_ROOT/etc/modprobe.d/iwlwifi-power.conf" 'options iwlwifi power_save=1
options iwlmvm power_scheme=3'
  w "$BO_ROOT/etc/modprobe.d/nvidia-power.conf" '# NVIDIA - Profile: Performance (performance)
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia NVreg_TemporaryFilePath=/tmp'
  w "$BO_ROOT/etc/modprobe.d/blacklist-nouveau.conf" 'blacklist nouveau
options nouveau modeset=0'
  w "$BO_ROOT/etc/modprobe.d/iwlwifi.conf" '# stock Ubuntu file — must survive
options iwlwifi 11n_disable=0'
  w "$BO_ROOT/etc/udev/rules.d/80-nvidia-pm.rules" '# NVIDIA - Runtime power management (vendor-wide)
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{power/control}="auto"'
  w "$BO_ROOT/etc/sysctl.d/99-battery-optimizer.conf" '# Profile: Performance (performance)
vm.laptop_mode = 3'
  w "$BO_ROOT/etc/tlp.conf" '# TLP Config - ThinkPad P14s Gen 3
# Profile: Performance (performance) | v1.1.0
TLP_ENABLE=1'
  w "$BO_ROOT/etc/systemd/system/battery-brightness.path" '[Path]'
  w "$BO_ROOT/etc/systemd/system/battery-brightness.service" '[Service]'
  w "$BO_ROOT/usr/local/bin/battery-brightness-cap.sh" '#!/bin/bash'
  w "$BO_ROOT/etc/battery-optimizer/mode" performance
}

# tree_snapshot DIR — path + checksum of every file and symlink
tree_snapshot() {
  (cd "$1" && find . \( -type f -o -type l \) -print0 | sort -z \
     | xargs -0 -r sha256sum 2>/dev/null; find . -type l -printf '%p -> %l\n' | sort)
}

called() { grep -qF -- "$1" "$BO_TEST_LOG"; }
