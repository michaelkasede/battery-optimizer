#!/usr/bin/env bats
# v1.x migration removes exactly the listed parameters and files.

load helpers

REF_CMDLINE="quiet splash iommu=pt intel_iommu=on i915.enable_gvt=1 kvm.ignore_msrs=1 pcie_acs_override=downstream,multifunction vfio_iommu_type1.allow_unsafe_interrupts=1 nmi_watchdog=0 mem_sleep_default=deep i915.enable_psr=2 i915.enable_fbc=1 i915.enable_rc6=7 nvme_core.default_ps_max_latency_us=5500 intel_idle.max_cstate=9 usbcore.autosuspend=5 pcie_aspm=force"

setup() { setup_env; lib_env; }

@test "reference cmdline: legacy params removed, VFIO params kept, order preserved" {
  run grub_strip_legacy "$REF_CMDLINE"
  [ "$output" = "quiet splash iommu=pt intel_iommu=on kvm.ignore_msrs=1 pcie_acs_override=downstream,multifunction vfio_iommu_type1.allow_unsafe_interrupts=1 nmi_watchdog=0 mem_sleep_default=deep" ]
}

@test "keys are matched exactly (no prefix matches)" {
  run grub_strip_legacy "pcie_aspm.policy=powersave pcie_aspm=off i915.enable_fbcx=1"
  [ "$output" = "pcie_aspm.policy=powersave i915.enable_fbcx=1" ]
}

@test "grub_rewrite only touches the cmdline variables" {
  cat > "$TMP/grub" <<'G'
# comment with pcie_aspm=force
GRUB_DEFAULT=0
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pcie_aspm=force"
GRUB_CMDLINE_LINUX='i915.enable_psr=2 rootflags=x'
GRUB_TIMEOUT_STYLE=hidden
G
  run grub_rewrite "$TMP/grub"
  [ "${lines[0]}" = "# comment with pcie_aspm=force" ]
  [ "${lines[2]}" = 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' ]
  [ "${lines[3]}" = "GRUB_CMDLINE_LINUX='rootflags=x'" ]
  [ "${lines[4]}" = "GRUB_TIMEOUT_STYLE=hidden" ]
}

@test "detects every v1.1 artifact and leaves stock files alone" {
  fixture_p14s; fake_stock_system; fake_v11_artifacts; detect_all
  migrate_detect
  migrate_needed
  [ "$MIGRATE_GRUB" = 1 ] && [ "$MIGRATE_TLP_CONF" = 1 ]
  for f in /etc/modprobe.d/i915-power.conf /etc/modprobe.d/iwlwifi-power.conf \
           /etc/modprobe.d/nvidia-power.conf /etc/modprobe.d/blacklist-nouveau.conf \
           /etc/udev/rules.d/80-nvidia-pm.rules /etc/sysctl.d/99-battery-optimizer.conf \
           /etc/tlp.conf /usr/local/bin/battery-brightness-cap.sh /etc/battery-optimizer/mode; do
    [[ " ${MIGRATE_FILES[*]} " == *" $f "* ]] || { echo "missing $f"; false; }
  done
  [[ " ${MIGRATE_FILES[*]} " != *iwlwifi.conf\ * ]]
  [[ " ${MIGRATE_UNITS[*]} " == *" battery-brightness.path "* ]]
}

@test "a user's own tlp.conf or nouveau blacklist is not a v1.1 artifact" {
  fixture_p14s; fake_stock_system; detect_all
  w "$BO_ROOT/etc/tlp.conf" '# my settings
TLP_ENABLE=1'
  w "$BO_ROOT/etc/modprobe.d/blacklist-nouveau.conf" 'blacklist nouveau
options nouveau modeset=0
alias nouveau off'
  migrate_detect
  ! migrate_needed
}

@test "apply backs up, removes, and rewrites GRUB" {
  fixture_p14s; fake_stock_system; fake_v11_artifacts; detect_all
  migrate_detect
  migrate_apply
  [ ! -e "$BO_ROOT/etc/modprobe.d/i915-power.conf" ]
  [ ! -e "$BO_ROOT/etc/tlp.conf" ]
  [ -e "$BO_ROOT/etc/modprobe.d/iwlwifi.conf" ]
  [ -f "$BO_ROOT$BACKUP_DIR/etc/modprobe.d/i915-power.conf" ]
  [ -f "$BO_ROOT$BACKUP_DIR/etc/default/grub" ]
  grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iommu=pt intel_iommu=on kvm.ignore_msrs=1 pcie_acs_override=downstream,multifunction vfio_iommu_type1.allow_unsafe_interrupts=1 nmi_watchdog=0 mem_sleep_default=deep"' "$BO_ROOT/etc/default/grub"
  [ "$MIGRATE_BOOT_CHANGED" = 1 ]
  called "systemctl disable --now battery-brightness.path"
  migrate_detect
  ! migrate_needed
}
