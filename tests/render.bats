#!/usr/bin/env bats
# Renderers produce the expected drop-ins from fixtures (golden files).

load helpers

setup() {
  setup_env; lib_env
  conf_parse "$REPO/config/profiles.conf"
}

golden() {
  local name="$1"; shift
  "$@" > "$TMP/out"
  if [[ -n "${UPDATE_GOLDEN:-}" ]]; then cp "$TMP/out" "$REPO/tests/fixtures/expected/$name"; fi
  diff -u "$REPO/tests/fixtures/expected/$name" "$TMP/out"
}

@test "P14s TLP drop-in" {
  fixture_p14s; detect_all
  golden p14s-tlp.conf render_tlp_dropin
}

@test "AMD TLP drop-in: low-power mapped to quiet, BAT1 stop threshold only, no deep sleep" {
  fixture_amd; detect_all
  golden amd-tlp.conf render_tlp_dropin
  grep -qx 'PLATFORM_PROFILE_ON_SAV=quiet' "$TMP/out"
  ! grep -q START_CHARGE "$TMP/out"
  ! grep -q MEM_SLEEP "$TMP/out"
}

@test "no platform profile support: PLATFORM_PROFILE omitted (EPP used instead)" {
  fixture_nvidia_outputs; detect_all
  render_tlp_dropin > "$TMP/out"
  ! grep -q PLATFORM_PROFILE "$TMP/out"
  grep -qx 'CPU_ENERGY_PERF_POLICY_ON_SAV=power' "$TMP/out"
  ! grep -q CHARGE_THRESH "$TMP/out"
}

@test "auto-switch and charge overrides" {
  fixture_p14s; detect_all
  AUTO_SWITCH=2
  conf_set CHARGE_START 60; conf_set CHARGE_STOP 90
  render_tlp_dropin > "$TMP/out"
  grep -qx TLP_AUTO_SWITCH=2 "$TMP/out"
  grep -qx START_CHARGE_THRESH_BAT0=60 "$TMP/out"
  grep -qx STOP_CHARGE_THRESH_BAT0=90 "$TMP/out"
}

@test "TLP drop-in never sets keys without an _ON_SAV variant to SAV" {
  fixture_p14s; detect_all
  render_tlp_dropin > "$TMP/out"
  ! grep -E '^(PCIE_ASPM|WIFI_PWR|RUNTIME_PM|INTEL_GPU_[A-Z_]+|SOUND_POWER_SAVE)_ON_SAV=' "$TMP/out"
}

@test "P14s hook.conf, NVIDIA modprobe and udev rules" {
  fixture_p14s; detect_all
  golden p14s-hook.conf render_hook_conf
  golden p14s-nvidia-modprobe.conf render_nvidia_modprobe
  golden p14s-udev.rules render_udev_rules
  golden hook.service render_hook_unit
}

@test "AMD: no NVIDIA udev rules, no iGPU frequency cap (not i915)" {
  fixture_amd; detect_all
  render_udev_rules > "$TMP/out"
  ! grep -q 0x10de "$TMP/out"
  render_hook_conf > "$TMP/out"
  grep -qx 'HOOK_IGPU_PCI=' "$TMP/out"
}

@test "pre-Turing NVIDIA: no DynamicPowerManagement option" {
  fixture_p14s
  w "$BO_SYSFS/bus/pci/devices/0000:03:00.0/device" 0x1c8d
  detect_all
  render_nvidia_modprobe > "$TMP/out"
  ! grep -q '^options nvidia NVreg_DynamicPowerManagement' "$TMP/out"
  grep -q 'NVreg_TemporaryFilePath=/var/tmp' "$TMP/out"
}

@test "template values containing & are not mangled" {
  printf 'x=@V@\n' > "$TMP/t"
  run render_template "$TMP/t" "V=a&b"
  [ "$output" = "x=a&b" ]
}

@test "unrendered placeholders are an error" {
  printf 'x=@MISSING@\n' > "$TMP/t"
  run render_template "$TMP/t"
  [ "$status" -ne 0 ]
}
