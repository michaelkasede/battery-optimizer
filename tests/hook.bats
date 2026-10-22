#!/usr/bin/env bats
# Profile hook: Power Saver extras applied once, restored exactly once.

load helpers

setup() {
  setup_env
  fixture_p14s
  python3 -c 'import sys' 2>/dev/null || skip "python3 missing"
  HOOK="$REPO/hook/profile-hook"
  CONF="$TMP/hook.conf"
  cat > "$CONF" <<C
HOOK_BRIGHTNESS_CAP_PCT=40
HOOK_DOCKER=stop
HOOK_IGPU_MAX_PCT=30
HOOK_BACKLIGHT=intel_backlight
HOOK_IGPU_PCI=0000:00:02.0
C
  BL="$BO_SYSFS/class/backlight/intel_backlight"
  GT="$BO_SYSFS/bus/pci/devices/0000:00:02.0/drm/card1"
}

hook() { python3 -I "$HOOK" --config "$CONF" --state-dir "$TMP/state" --sysfs "$BO_SYSFS" --no-dbus "$@"; }

@test "power-saver caps brightness and iGPU; balanced restores them" {
  hook --profile power-saver
  [ "$(cat "$BL/brightness")" = $((19393 * 40 / 100)) ]
  [ "$(cat "$GT/gt_max_freq_mhz")" = $((100 + 1350 * 30 / 100)) ]
  [ "$(cat "$GT/gt_boost_freq_mhz")" = 505 ]
  hook --profile balanced
  [ "$(cat "$BL/brightness")" = 15000 ]
  [ "$(cat "$GT/gt_max_freq_mhz")" = 1450 ]
  [ "$(cat "$GT/gt_boost_freq_mhz")" = 1450 ]
}

@test "repeated power-saver events are idempotent" {
  hook --profile power-saver
  hook --profile power-saver
  hook --profile balanced
  [ "$(cat "$BL/brightness")" = 15000 ]
}

@test "a brightness the user changed in Power Saver is kept" {
  hook --profile power-saver
  echo 3000 > "$BL/brightness"
  hook --profile performance
  [ "$(cat "$BL/brightness")" = 3000 ]
}

@test "dim panel below the cap is left alone" {
  echo 2000 > "$BL/brightness"
  hook --profile power-saver
  [ "$(cat "$BL/brightness")" = 2000 ]
  hook --profile balanced
  [ "$(cat "$BL/brightness")" = 2000 ]
}

@test "--restore undoes everything" {
  hook --profile power-saver
  hook --restore
  [ "$(cat "$BL/brightness")" = 15000 ]
  [ "$(cat "$GT/gt_max_freq_mhz")" = 1450 ]
}

@test "state survives across runs (e.g. reboot while in Power Saver)" {
  hook --profile power-saver
  [ -f "$TMP/state/state.json" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["brightness"]["saved"]==15000' "$TMP/state/state.json"
}

@test "invalid config is rejected" {
  echo 'HOOK_BACKLIGHT=../../../etc' >> "$CONF"
  run hook --profile power-saver
  [ "$status" -eq 2 ]
  [ "$(cat "$BL/brightness")" = 15000 ]
  echo 'EVIL=1' > "$CONF"
  run hook --profile power-saver
  [ "$status" -eq 2 ]
}
