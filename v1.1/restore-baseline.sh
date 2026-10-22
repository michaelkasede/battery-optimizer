#!/bin/bash
# ============================================================
#  restore-baseline.sh — undo the risky parts of battery-optimizer v1.1
#  ThinkPad P14s Gen 3 (Intel) | Ubuntu 24.04
#
#  What it does:
#    - Removes forced/obsolete kernel params from GRUB:
#        i915.enable_fbc  i915.enable_psr  i915.enable_rc6  i915.enable_gvt
#        pcie_aspm=force  intel_idle.max_cstate  usbcore.autosuspend
#        nvme_core.default_ps_max_latency_us
#      (keeps quiet, splash, nmi_watchdog, mem_sleep_default and all
#       virtualization params: intel_iommu, iommu, vfio_*, kvm.*, pcie_acs_override)
#    - Moves /etc/modprobe.d/i915-power.conf and iwlwifi-power.conf to a backup
#      folder (drivers go back to their own defaults)
#    - Adds any connected Logitech receivers to TLP's USB_DENYLIST
#    - Rebuilds initramfs and GRUB
#  Keeps: TLP, thermald, NVIDIA runtime PM, nouveau blacklist, charge thresholds.
#
#  Usage:  sudo bash restore-baseline.sh --dry-run   # show what would change
#          sudo bash restore-baseline.sh             # apply, then reboot
# ============================================================
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0 [--dry-run]"; exit 1
fi

TS=$(date +%Y%m%d-%H%M%S)
BACKUP="/etc/battery-optimizer/backup-$TS"
GRUB_FILE=/etc/default/grub
TLP_FILE=/etc/tlp.conf

run() { if (( DRY_RUN )); then echo "  [dry-run] $*"; else "$@"; fi; }

echo "== Backup → $BACKUP"
run mkdir -p "$BACKUP"
for f in "$GRUB_FILE" "$TLP_FILE" /etc/modprobe.d/i915-power.conf /etc/modprobe.d/iwlwifi-power.conf; do
  [[ -f "$f" ]] && run cp -a "$f" "$BACKUP/"
done

# ---------- GRUB ----------
echo "== GRUB kernel parameters"
REMOVE_KEYS=(i915.enable_fbc i915.enable_psr i915.enable_rc6 i915.enable_gvt
             pcie_aspm intel_idle.max_cstate usbcore.autosuspend
             nvme_core.default_ps_max_latency_us)

CURRENT=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/')
NEW=()
for p in $CURRENT; do
  key=${p%%=*}
  drop=0
  for k in "${REMOVE_KEYS[@]}"; do [[ "$key" == "$k" ]] && drop=1 && break; done
  (( drop )) && echo "  - remove $p" || NEW+=("$p")
done
NEW_STR="${NEW[*]}"
echo "  before: $CURRENT"
echo "  after:  $NEW_STR"
if [[ "$CURRENT" != "$NEW_STR" ]]; then
  run sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_STR\"|" "$GRUB_FILE"
fi

# ---------- modprobe.d ----------
echo "== Driver option files"
for f in /etc/modprobe.d/i915-power.conf /etc/modprobe.d/iwlwifi-power.conf; do
  if [[ -f "$f" ]]; then
    echo "  - move $f → $BACKUP/ (driver defaults restored)"
    run rm -f "$f"
  fi
done

# ---------- TLP USB denylist ----------
echo "== TLP USB denylist (Logitech receivers)"
if [[ -f "$TLP_FILE" ]] && command -v lsusb >/dev/null; then
  CUR_DENY=$(grep -E '^USB_DENYLIST=' "$TLP_FILE" | sed -E 's/^USB_DENYLIST="?([^"]*)"?$/\1/' || true)
  ADD=""
  for id in $(lsusb | grep -i logitech | awk '{print $6}'); do
    [[ " $CUR_DENY $ADD " == *" $id "* ]] || ADD="$ADD $id"
  done
  if [[ -n "$ADD" ]]; then
    NEW_DENY=$(echo "$CUR_DENY$ADD" | xargs)
    echo "  + add:$ADD"
    if grep -qE '^USB_DENYLIST=' "$TLP_FILE"; then
      run sed -i "s|^USB_DENYLIST=.*|USB_DENYLIST=\"$NEW_DENY\"|" "$TLP_FILE"
    else
      (( DRY_RUN )) && echo "  [dry-run] append USB_DENYLIST" || echo "USB_DENYLIST=\"$NEW_DENY\"" >> "$TLP_FILE"
    fi
  else
    echo "  nothing to add"
  fi
fi

# ---------- Rebuild ----------
echo "== Rebuild initramfs + GRUB"
run update-initramfs -u
run update-grub

if (( DRY_RUN )); then
  echo -e "\nDry run only — nothing changed. Re-run without --dry-run to apply."
else
  run systemctl restart tlp || true
  echo -e "\nDone. Backups in $BACKUP"
  echo "Reboot, then verify:  cat /proc/cmdline ; ls /etc/modprobe.d/"
  echo "Undo:  sudo cp $BACKUP/grub /etc/default/grub; sudo cp $BACKUP/tlp.conf /etc/tlp.conf;"
  echo "       sudo cp $BACKUP/i915-power.conf $BACKUP/iwlwifi-power.conf /etc/modprobe.d/ 2>/dev/null;"
  echo "       sudo update-initramfs -u && sudo update-grub"
fi
