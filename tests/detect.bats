#!/usr/bin/env bats
# Hardware detection against fixture sysfs trees.

load helpers

setup() { setup_env; lib_env; }

@test "P14s Gen 3: Intel iGPU + NVIDIA T550 3D controller" {
  fixture_p14s
  detect_all
  [ "$OS_ID" = ubuntu ] && [ "$OS_VERSION_ID" = 24.04 ]
  [ "$CPU_VENDOR" = intel ]
  [ "$IGPU_PCI" = 0000:00:02.0 ] && [ "$IGPU_DRIVER" = i915 ]
  [ "$DGPU_PCI" = 0000:03:00.0 ] && [ "$DGPU_VENDOR" = nvidia ] && [ "$DGPU_DRIVER" = nvidia ]
  ! dgpu_has_outputs
  nvidia_supports_rtd3
  [ "${BATTERIES[*]}" = BAT0 ] && [ "${BAT_START[BAT0]}" = 1 ] && [ "${BAT_STOP[BAT0]}" = 1 ]
  [ "$BACKLIGHT" = intel_backlight ]
  [ "$PP_CHOICES" = "low-power balanced performance" ]
  mem_sleep_supports deep
  [ "${USB_RECEIVERS[*]}" = 046d:c548 ]
  platform_supported
}

@test "AMD laptop: iGPU identified by eDP connector, not PCI bus" {
  fixture_amd
  detect_all
  [ "$IGPU_PCI" = 0000:05:00.0 ]
  [ "$DGPU_PCI" = 0000:03:00.0 ] && [ "$DGPU_VENDOR" = amd ]
  dgpu_has_outputs
  ! nvidia_supports_rtd3
  [ "${BATTERIES[*]}" = BAT1 ] && [ "${BAT_START[BAT1]}" = 0 ] && [ "${BAT_STOP[BAT1]}" = 1 ]
  [ "$BACKLIGHT" = amdgpu_bl1 ]
  ! mem_sleep_supports deep
  [ ${#USB_RECEIVERS[@]} -eq 0 ]
}

@test "NVIDIA with outputs: VGA class, firmware backlight preferred over unlinked raw" {
  fixture_nvidia_outputs
  detect_all
  [ "$DGPU_PCI" = 0000:01:00.0 ] && dgpu_has_outputs
  nvidia_supports_rtd3
  [ "$BACKLIGHT" = acpi_video0 ]
  [ -z "$PP_CHOICES" ]
  [ "${BAT_START[BAT0]}" = 0 ] && [ "${BAT_STOP[BAT0]}" = 0 ]
}

@test "pre-Turing NVIDIA GPU has no RTD3" {
  fixture_p14s
  w "$BO_SYSFS/bus/pci/devices/0000:03:00.0/device" 0x1c8d
  detect_gpus
  ! nvidia_supports_rtd3
}

@test "HID batteries (scope=Device) are not system batteries" {
  fixture_p14s
  w "$BO_SYSFS/class/power_supply/hidpp_battery_0/type" Battery
  w "$BO_SYSFS/class/power_supply/hidpp_battery_0/scope" Device
  detect_power_supplies
  [ "${BATTERIES[*]}" = BAT0 ]
}

@test "unsupported platforms are refused" {
  fixture_p14s
  w "$BO_ROOT/etc/os-release" 'ID=fedora
VERSION_ID="40"'
  rm -rf "$BO_SYSFS/bus/pci/devices/0000:03:00.0"
  detect_all
  run platform_supported
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsupported OS"* ]]
  [[ "$output" == *"No discrete GPU"* ]]
}

@test "weak VFIO boot parameters are reported" {
  run weak_boot_param_warnings "quiet vfio_iommu_type1.allow_unsafe_interrupts=1 pcie_acs_override=downstream"
  [[ "$output" == *allow_unsafe_interrupts* ]]
  [[ "$output" == *pcie_acs_override* ]]
  run weak_boot_param_warnings "quiet splash"
  [ -z "$output" ]
}
