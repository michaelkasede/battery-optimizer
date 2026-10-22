#!/usr/bin/env bats
# End-to-end install / uninstall against a fake root with stubbed commands.

load helpers

setup() {
  setup_env
  fixture_p14s
  fake_stock_system
}

@test "install --dry-run changes nothing" {
  fake_v11_artifacts
  before=$(tree_snapshot "$BO_ROOT")
  run "$CLI" install --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(tree_snapshot "$BO_ROOT")" = "$before" ]
  [[ "$output" == *"[dry-run] apt-get install"* ]]
  [[ "$output" == *"STOP_CHARGE_THRESH_BAT0=80"* ]]
  ! grep -qE '^(apt-get install|systemctl (enable|mask|disable)|update-grub|prime-select on)' "$BO_TEST_LOG"
}

@test "install writes drop-ins, records a manifest and replaces power-profiles-daemon" {
  run "$CLI" install --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$BO_ROOT/etc/tlp.d/50-battery-optimizer.conf" ]
  [ -f "$BO_ROOT/etc/battery-optimizer/hook.conf" ]
  [ -f "$BO_ROOT/etc/systemd/system/battery-optimizer-hook.service" ]
  [ -f "$BO_ROOT/etc/udev/rules.d/80-battery-optimizer.rules" ]
  [ -f "$BO_ROOT/etc/modprobe.d/50-battery-optimizer-nvidia.conf" ]
  [ -x "$BO_ROOT/usr/local/sbin/battery-optimizer" ]
  [ -x "$BO_ROOT/usr/local/lib/battery-optimizer/hook/profile-hook" ]
  [ ! -e "$BO_ROOT/etc/default/grub.d/50-battery-optimizer.cfg" ]   # no kernel params needed
  grep -q $'^file\t/etc/tlp.d/50-battery-optimizer.conf\t' "$BO_ROOT/etc/battery-optimizer/manifest"
  grep -q $'^pkg-del\tpower-profiles-daemon' "$BO_ROOT/etc/battery-optimizer/manifest"
  grep -q $'^ppa\tlinrunner/tlp' "$BO_ROOT/etc/battery-optimizer/manifest"
  called "apt-get install"
  grep -q 'power-profiles-daemon-' "$BO_TEST_LOG"
  ! grep -q '^power-profiles-daemon ' "$BO_ROOT/var/lib/stub/pkgs"
  grep -q '^tlp-pd 1.9' "$BO_ROOT/var/lib/stub/pkgs"
  called "update-initramfs -u"
  ! called "update-grub"
  called "tlp start"
  # every manifest checksum matches the file on disk
  while IFS=$'\t' read -r t f sum; do
    [ "$t" = file ] || continue
    [ "$(sha256sum "$BO_ROOT$f" | cut -d' ' -f1)" = "$sum" ] || { echo "bad sum: $f"; false; }
  done < <(grep -v '^#' "$BO_ROOT/etc/battery-optimizer/manifest")
}

@test "installed files are not group/world writable" {
  "$CLI" install --yes >/dev/null
  run find "$BO_ROOT/etc/tlp.d" "$BO_ROOT/etc/battery-optimizer" "$BO_ROOT/usr/local" -type f -perm /022
  [ -z "$output" ]
}

@test "second install is idempotent" {
  "$CLI" install --yes >/dev/null
  m1=$(cat "$BO_ROOT/etc/battery-optimizer/manifest")
  : > "$BO_TEST_LOG"
  run "$CLI" install --yes
  [ "$status" -eq 0 ]
  [[ "$output" != *"wrote "* ]]
  [ "$(cat "$BO_ROOT/etc/battery-optimizer/manifest")" = "$m1" ]
  ! called "update-initramfs"
  ! called "add-apt-repository"
}

@test "install migrates v1.1 leftovers and rebuilds GRUB" {
  fake_v11_artifacts
  run "$CLI" install --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$BO_ROOT/etc/modprobe.d/nvidia-power.conf" ]
  [ ! -e "$BO_ROOT/etc/systemd/system/battery-brightness.path" ]
  ! grep -q 'pcie_aspm=force' "$BO_ROOT/etc/default/grub"
  ls "$BO_ROOT"/etc/battery-optimizer/backup-*/etc/tlp.conf
  called "update-grub"
  [[ "$output" == *"Reboot required"* ]]
}

@test "without --yes and without a terminal, leftovers are kept" {
  fake_v11_artifacts
  run "$CLI" install < /dev/null
  [ "$status" -eq 0 ]
  [ -e "$BO_ROOT/etc/modprobe.d/i915-power.conf" ]
  [[ "$output" == *"leftovers kept"* ]]
}

@test "tuned is disabled and masked, and restored on uninstall" {
  fake_pkgs tuned
  fake_units tuned.service=enabled
  sort -o "$BO_ROOT/var/lib/stub/units" "$BO_ROOT/var/lib/stub/units"
  "$CLI" install --yes >/dev/null
  grep -qx 'tuned.service masked' "$BO_ROOT/var/lib/stub/units"
  "$CLI" uninstall --yes >/dev/null
  grep -qx 'tuned.service enabled' "$BO_ROOT/var/lib/stub/units"
}

@test "edited drop-in is backed up on reinstall" {
  "$CLI" install --yes >/dev/null
  echo "CPU_MAX_PERF_ON_SAV=99" >> "$BO_ROOT/etc/tlp.d/50-battery-optimizer.conf"
  run "$CLI" install --yes
  [[ "$output" == *"edited locally"* ]]
  ls "$BO_ROOT"/etc/battery-optimizer/backup-*/etc/tlp.d/50-battery-optimizer.conf
  ! grep -q '=99' "$BO_ROOT/etc/tlp.d/50-battery-optimizer.conf"
}

@test "uninstall round-trip restores the fake root exactly" {
  before=$(tree_snapshot "$BO_ROOT")
  "$CLI" install --yes >/dev/null
  run "$CLI" uninstall --yes
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  diff <(echo "$before") <(tree_snapshot "$BO_ROOT")
  called "add-apt-repository -y --remove ppa:linrunner/tlp"
  called "update-initramfs -u"
}

@test "uninstall --dry-run changes nothing" {
  "$CLI" install --yes >/dev/null
  before=$(tree_snapshot "$BO_ROOT")
  run "$CLI" uninstall --dry-run
  [ "$status" -eq 0 ]
  [ "$(tree_snapshot "$BO_ROOT")" = "$before" ]
}

@test "unsupported platform needs --force" {
  rm -rf "$BO_SYSFS/bus/pci/devices/0000:03:00.0"
  run "$CLI" install --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--force"* ]]
  run "$CLI" install --dry-run --force
  [ "$status" -eq 0 ]
}

@test "previous prime-select mode is restored on uninstall" {
  echo nvidia > "$BO_ROOT/var/lib/stub/prime"
  "$CLI" install --yes >/dev/null
  [ "$(cat "$BO_ROOT/var/lib/stub/prime")" = on-demand ]
  "$CLI" uninstall --yes >/dev/null
  [ "$(cat "$BO_ROOT/var/lib/stub/prime")" = nvidia ]
}
