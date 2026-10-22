#!/usr/bin/env bats
# CLI surface: arguments, status, measure guards.

load helpers

setup() { setup_env; fixture_p14s; fake_stock_system; }

@test "--version prints VERSION" {
  run "$CLI" --version
  [ "$output" = "battery-optimizer $(cat "$REPO/VERSION")" ]
}

@test "unknown command and options fail" {
  run "$CLI" frobnicate
  [ "$status" -eq 2 ]
  run "$CLI" install --bogus
  [ "$status" -ne 0 ]
  run "$CLI" install --auto-switch 7 --dry-run
  [ "$status" -ne 0 ]
  run "$CLI" install --charge 90:80 --dry-run
  [ "$status" -ne 0 ]
}

@test "--charge and --auto-switch reach the TLP drop-in" {
  run "$CLI" install --dry-run --charge 50:85 --auto-switch 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"TLP_AUTO_SWITCH=2"* ]]
  [[ "$output" == *"START_CHARGE_THRESH_BAT0=50"* ]]
  [[ "$output" == *"STOP_CHARGE_THRESH_BAT0=85"* ]]
}

@test "status reports hardware, VFIO warnings and not-installed state" {
  run "$CLI" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"0000:03:00.0 (nvidia"* ]]
  [[ "$output" == *"allow_unsafe_interrupts"* ]]
  [[ "$output" == *"legacy parameters: i915.enable_fbc i915.enable_psr i915.enable_gvt pcie_aspm"* ]]
  [[ "$output" == *"not installed"* ]]
}

@test "status shows modified files after install" {
  "$CLI" install --yes >/dev/null
  echo "# local edit" >> "$BO_ROOT/etc/battery-optimizer/hook.conf"
  run "$CLI" status
  [[ "$output" == *"/etc/tlp.d/50-battery-optimizer.conf"*ok* ]]
  [[ "$output" == *"hook.conf"*modified* ]]
}

@test "measure refuses to run on AC" {
  w "$BO_SYSFS/class/power_supply/BAT0/status" Charging
  run "$CLI" measure 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"unplug"* ]]
}

@test "measure validates its arguments" {
  run "$CLI" measure 0
  [ "$status" -ne 0 ]
  run "$CLI" measure 500
  [ "$status" -ne 0 ]
  run "$CLI" measure 5 --interval 0
  [ "$status" -ne 0 ]
}

@test "world-writable repo files are refused" {
  cp -r "$REPO" "$TMP/repo"
  chmod o+w "$TMP/repo/config/profiles.conf"
  run "$TMP/repo/battery-optimizer" install --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"world-writable"* ]]
}
