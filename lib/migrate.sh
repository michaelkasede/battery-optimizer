# shellcheck shell=bash
# Detect and remove v1.0/v1.1 artifacts (folds in v1.1/restore-baseline.sh).
# Every removed file is backed up first; nothing is restored on uninstall
# because these settings were harmful or are superseded by v1.2.

# Kernel parameters written by v1.0/v1.1 (or found on the reference machine)
# that are risky, obsolete or duplicate TLP. VFIO/IOMMU parameters are never
# touched (see `status` for warnings about them).
LEGACY_GRUB_KEYS=(
  i915.enable_fbc i915.enable_psr i915.enable_rc6 i915.enable_gvt
  i915.lvds_downclock i915.semaphores pcie_aspm intel_idle.max_cstate
  usbcore.autosuspend nvme_core.default_ps_max_latency_us
)

declare -ga MIGRATE_FILES=() MIGRATE_UNITS=() MIGRATE_NOTES=()
MIGRATE_GRUB=0
MIGRATE_TLP_CONF=0

# grub_strip_legacy "PARAMS" — print PARAMS without LEGACY_GRUB_KEYS
grub_strip_legacy() {
  local param key k out=() drop
  for param in $1; do
    key="${param%%=*}"
    drop=0
    for k in "${LEGACY_GRUB_KEYS[@]}"; do
      [[ "$key" == "$k" ]] && { drop=1; break; }
    done
    (( drop )) || out+=("$param")
  done
  printf '%s' "${out[*]}"
}

# grub_rewrite FILE — print FILE with legacy params removed from
# GRUB_CMDLINE_LINUX and GRUB_CMDLINE_LINUX_DEFAULT; other lines untouched
grub_rewrite() {
  local line var q val
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^(GRUB_CMDLINE_LINUX(_DEFAULT)?)=([\"\'])(.*)([\"\'])[[:space:]]*$ ]] \
       && [[ "${BASH_REMATCH[3]}" == "${BASH_REMATCH[5]}" ]]; then
      var="${BASH_REMATCH[1]}"; q="${BASH_REMATCH[3]}"; val="${BASH_REMATCH[4]}"
      printf '%s=%s%s%s\n' "$var" "$q" "$(grub_strip_legacy "$val")" "$q"
    else
      printf '%s\n' "$line"
    fi
  done < "$1"
}

file_contains() { [[ -f "$1" ]] && grep -qE -- "$2" "$1"; }

# Only the two nouveau lines (plus comments/blank lines) — as v1.0/v1.1 wrote it
is_legacy_nouveau_blacklist() {
  local f="$1" body
  [[ -f "$f" ]] || return 1
  body=$(grep -vE '^[[:space:]]*(#|$)' "$f" | tr -s ' ')
  [[ "$body" == $'blacklist nouveau\noptions nouveau modeset=0' ]]
}

migrate_detect() {
  MIGRATE_FILES=(); MIGRATE_UNITS=(); MIGRATE_NOTES=()
  MIGRATE_GRUB=0; MIGRATE_TLP_CONF=0
  local f u

  file_contains "$(p /etc/modprobe.d/i915-power.conf)" 'options i915' \
    && MIGRATE_FILES+=(/etc/modprobe.d/i915-power.conf)
  file_contains "$(p /etc/modprobe.d/iwlwifi-power.conf)" 'options iwl' \
    && MIGRATE_FILES+=(/etc/modprobe.d/iwlwifi-power.conf)
  file_contains "$(p /etc/modprobe.d/nvidia-power.conf)" '^# NVIDIA' \
    && MIGRATE_FILES+=(/etc/modprobe.d/nvidia-power.conf)
  # superseded by our NVIDIA modprobe drop-in, which blacklists nouveau too
  if [[ "$DGPU_VENDOR" == nvidia ]] && is_legacy_nouveau_blacklist "$(p /etc/modprobe.d/blacklist-nouveau.conf)"; then
    MIGRATE_FILES+=(/etc/modprobe.d/blacklist-nouveau.conf)
  fi
  file_contains "$(p /etc/udev/rules.d/80-nvidia-pm.rules)" '^# NVIDIA.*Runtime power management' \
    && MIGRATE_FILES+=(/etc/udev/rules.d/80-nvidia-pm.rules)
  file_contains "$(p /etc/sysctl.d/99-battery-optimizer.conf)" '^# (ThinkPad P14s|Profile:)' \
    && MIGRATE_FILES+=(/etc/sysctl.d/99-battery-optimizer.conf)
  if file_contains "$(p /etc/tlp.conf)" '^# TLP Config - ThinkPad P14s'; then
    MIGRATE_FILES+=(/etc/tlp.conf)
    MIGRATE_TLP_CONF=1
  fi

  for u in battery-brightness.path battery-brightness.service \
           docker-battery-manager.path docker-battery-manager.service; do
    [[ -f "$(p "/etc/systemd/system/$u")" ]] && MIGRATE_UNITS+=("$u")
  done
  if file_contains "$(p /etc/systemd/system/powertop.service)" 'auto-tune'; then
    MIGRATE_UNITS+=(powertop.service)
  fi

  for f in /usr/local/bin/battery-brightness-cap.sh /usr/local/bin/docker-battery-manager.sh \
           /etc/battery-optimizer/mode /var/lib/battery-optimizer/brightness-saved \
           /var/lib/battery-optimizer/docker-was-running; do
    [[ -f "$(p "$f")" ]] && MIGRATE_FILES+=("$f")
  done
  if [[ -f "$(p /var/lib/battery-optimizer/docker-was-running)" ]]; then
    MIGRATE_NOTES+=("v1.1 had stopped Docker on battery; start it again with: sudo systemctl start docker")
  fi

  f=$(p /etc/default/grub)
  if [[ -f "$f" ]] && ! diff -q <(grub_rewrite "$f") "$f" >/dev/null; then
    MIGRATE_GRUB=1
  fi
}

migrate_needed() {
  (( ${#MIGRATE_FILES[@]} + ${#MIGRATE_UNITS[@]} + MIGRATE_GRUB > 0 ))
}

migrate_print() {
  local f
  for f in "${MIGRATE_UNITS[@]}"; do info "- unit   /etc/systemd/system/$f (disable + remove)"; done
  for f in "${MIGRATE_FILES[@]}"; do info "- file   $f"; done
  if (( MIGRATE_GRUB )); then
    info "- GRUB   /etc/default/grub: remove legacy kernel parameters:"
    diff "$(p /etc/default/grub)" <(grub_rewrite "$(p /etc/default/grub)") \
      | sed -n 's/^< /           before: /p; s/^> /           after:  /p' || true
  fi
  for f in "${MIGRATE_NOTES[@]}"; do info "  note: $f"; done
}

# migrate_apply — sets MIGRATE_BOOT_CHANGED=1 when a reboot-relevant file changed
MIGRATE_BOOT_CHANGED=0
migrate_apply() {
  local f u tmp
  for u in "${MIGRATE_UNITS[@]}"; do
    runcmd_ok systemctl disable --now "$u"
    backup_file "/etc/systemd/system/$u"
    runcmd rm -f "$(p "/etc/systemd/system/$u")"
  done
  if (( ${#MIGRATE_UNITS[@]} )); then runcmd_ok systemctl daemon-reload; fi

  for f in "${MIGRATE_FILES[@]}"; do
    backup_file "$f"
    runcmd rm -f "$(p "$f")"
    is_boot_file "$f" && MIGRATE_BOOT_CHANGED=1
  done

  if (( MIGRATE_GRUB )); then
    backup_file /etc/default/grub
    if (( DRY_RUN )); then
      info "[dry-run] rewrite /etc/default/grub without legacy parameters"
    else
      tmp=$(mktemp)
      grub_rewrite "$(p /etc/default/grub)" > "$tmp"
      cat "$tmp" > "$(p /etc/default/grub)"   # keep owner/mode of the original
      rm -f "$tmp"
    fi
    MIGRATE_BOOT_CHANGED=1
  fi
  ok "v1.x leftovers removed (backups in ${BACKUP_DIR:-n/a})"
}
