#!/usr/bin/env bats
# Config parser: allow-listed KEY=VALUE only, never sourced.

load helpers

setup() { setup_env; lib_env; }

@test "repo profiles.conf parses" {
  conf_parse "$REPO/config/profiles.conf"
  [ "$(conf_get CPU_MAX_PERF_ON_SAV)" = 35 ]
  [ "$(conf_get PLATFORM_PROFILE_ON_SAV)" = low-power ]
  [ "$(conf_get RUNTIME_PM_DRIVER_DENYLIST)" = "mei_me nouveau nvidia amdgpu radeon xhci_hcd" ]
}

@test "unknown key is rejected" {
  f="$TMP/c.conf"; printf 'TLP_ENABLE=1\nEVIL_KEY=1\n' > "$f"
  run conf_parse "$f"
  [ "$status" -ne 0 ]
  [[ "$output" == *"key not allowed: TLP_ENABLE"* ]]
}

@test "command substitution in a value is rejected and never executed" {
  f="$TMP/c.conf"
  printf 'CPU_MAX_PERF_ON_BAT=$(touch %s/pwned)\n' "$TMP" > "$f"
  run conf_parse "$f"
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/pwned" ]
}

@test "out-of-range and malformed values are rejected" {
  for line in CPU_MAX_PERF_ON_SAV=101 WIFI_PWR_ON_BAT=maybe 'USB_DENYLIST="046d:c548;reboot"' \
              'HOOK_BACKLIGHT=../../etc' 'PLATFORM_PROFILE_ON_AC=turbo' 'CHARGE_STOP=-1'; do
    printf '%s\n' "$line" > "$TMP/c.conf"
    run conf_parse "$TMP/c.conf"
    [ "$status" -ne 0 ] || { echo "accepted: $line"; false; }
  done
}

@test "quoted values with spaces are accepted only for list keys" {
  printf 'USB_DENYLIST="046d:c548 046d:c52b"\n' > "$TMP/c.conf"
  conf_parse "$TMP/c.conf"
  [ "$(conf_get USB_DENYLIST)" = "046d:c548 046d:c52b" ]
  printf 'USB_DENYLIST=046d:c548 046d:c52b\n' > "$TMP/c.conf"
  run conf_parse "$TMP/c.conf"
  [ "$status" -ne 0 ]
}

@test "world-writable config is refused" {
  printf 'CHARGE_STOP=80\n' > "$TMP/c.conf"
  chmod 666 "$TMP/c.conf"
  run conf_parse "$TMP/c.conf"
  [ "$status" -ne 0 ]
  [[ "$output" == *world-writable* ]]
}

@test "conf_set validates overrides" {
  conf_set CHARGE_START 50
  [ "$(conf_get CHARGE_START)" = 50 ]
  run conf_set CHARGE_START abc
  [ "$status" -ne 0 ]
}
