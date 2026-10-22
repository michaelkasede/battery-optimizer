# shellcheck shell=bash
# System actions: packages, services, GPU, file installation, uninstall,
# measurement. Every mutating command goes through runcmd/runcmd_ok (dry-run aware)
# and every change is recorded in the manifest.

BOOT_CHANGED=0
GRUB_CHANGED=0
declare -ga PRODUCED=()

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ---------------------------------------------------------------- queries

pkg_installed() {
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" == installed ]]
}

pkg_version() {
  pkg_installed "$1" || return 1
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

unit_enabled_state() {
  local out
  out=$(systemctl is-enabled "$1" 2>/dev/null || true)
  printf '%s' "${out:-not-found}"
}

unit_active_state() {
  local out
  out=$(systemctl is-active "$1" 2>/dev/null || true)
  printf '%s' "${out:-unknown}"
}

unit_exists() { [[ "$(unit_enabled_state "$1")" != not-found ]]; }

apt_has_ppa() {
  grep -rqsF "$TLP_PPA" "$(p /etc/apt/sources.list.d)" 2>/dev/null
}

tlp_setting() {
  local line
  line=$(grep -E "^$1=" "$(p "$TLP_DROPIN")" 2>/dev/null | tail -1) || return 1
  printf '%s' "${line#*=}"
}

active_profile() {
  local out
  if have tlpctl && out=$(tlpctl get 2>/dev/null) && [[ -n "$out" ]]; then
    printf '%s' "$out"; return 0
  fi
  if have gdbus && out=$(gdbus call --system --dest org.freedesktop.UPower.PowerProfiles \
        --object-path /org/freedesktop/UPower/PowerProfiles \
        --method org.freedesktop.DBus.Properties.Get \
        org.freedesktop.UPower.PowerProfiles ActiveProfile 2>/dev/null); then
    out="${out#*\'}"; printf '%s' "${out%%\'*}"; return 0
  fi
  return 0
}

# battery_watts DIR — current draw in watts (empty if unknown)
battery_watts() {
  local d="$1" pw cur volt
  pw=$(read_sys "$d/power_now")
  if [[ "$pw" =~ ^[0-9]+$ ]]; then
    awk -v p="$pw" 'BEGIN { printf "%.2f", p / 1e6 }'
    return 0
  fi
  cur=$(read_sys "$d/current_now"); volt=$(read_sys "$d/voltage_now")
  if [[ "$cur" =~ ^[0-9]+$ && "$volt" =~ ^[0-9]+$ ]]; then
    awk -v c="$cur" -v v="$volt" 'BEGIN { printf "%.2f", c * v / 1e12 }'
  fi
  return 0
}

# ---------------------------------------------------------------- install steps

# record_unit UNIT — remember the unit's original enablement state
record_unit() { manifest_set_once svc "$1" "$(unit_enabled_state "$1")"; }

step_packages() {
  local pkgs=(tlp tlp-rdw tlp-pd python3-gi) remove=() p ver tlp_was_installed=0
  [[ "$CPU_VENDOR" == intel ]] && pkgs+=(thermald)
  pkg_installed tlp && tlp_was_installed=1

  if apt_has_ppa; then
    ok "ppa:$TLP_PPA already configured"
  else
    have add-apt-repository || runcmd apt-get install "${APT_OPTS[@]}" software-properties-common
    runcmd add-apt-repository -y "ppa:$TLP_PPA"
    (( DRY_RUN )) || manifest_set_once ppa "$TLP_PPA" -
  fi
  runcmd apt-get update -q

  for p in "${pkgs[@]}"; do
    if pkg_installed "$p"; then
      info "installed  $p"
    else
      (( DRY_RUN )) || manifest_set_once pkg-add "$p" -
    fi
  done
  # tlp-pd replaces these; apt would remove them through Conflicts anyway
  for p in power-profiles-daemon tuned-ppd; do
    if pkg_installed "$p"; then
      remove+=("$p-")
      (( DRY_RUN )) || manifest_set_once pkg-del "$p" -
    fi
  done

  runcmd apt-get install "${APT_OPTS[@]}" "${pkgs[@]}" "${remove[@]}"
  # restore the package's /etc/tlp.conf if migration removed a v1.x one
  # (a fresh install creates it anyway)
  if (( MIGRATE_TLP_CONF && tlp_was_installed )); then
    runcmd apt-get install "${APT_OPTS[@]}" --reinstall -o Dpkg::Options::=--force-confmiss tlp
  fi

  if (( ! DRY_RUN )); then
    ver=$(pkg_version tlp) || die "TLP is not installed — check the apt output above"
    version_ge "${ver%%-*}" "$TLP_MIN_VERSION" \
      || die "TLP $ver is too old; >= $TLP_MIN_VERSION with tlp-pd is required (ppa:$TLP_PPA)"
    pkg_installed tlp-pd || die "tlp-pd is not installed"
    ok "TLP $ver with tlp-pd"
  fi
}

step_gpu() {
  local dev ctl u prev
  case "$DGPU_VENDOR" in
    nvidia)
      if [[ "$DGPU_DRIVER" == nvidia ]] || modinfo nvidia >/dev/null 2>&1; then
        ok "NVIDIA proprietary driver present"
      else
        warn "NVIDIA proprietary driver not found — install it first: sudo ubuntu-drivers install"
      fi
      if nvidia_supports_rtd3; then
        ok "Turing or newer: NVreg_DynamicPowerManagement=0x02"
      else
        warn "pre-Turing NVIDIA GPU: runtime D3 unsupported; dGPU may stay powered"
      fi
      if have prime-select; then
        prev=$(prime-select query 2>/dev/null || true)
        (( DRY_RUN )) || manifest_set_once prime - "${prev:-unknown}"
        if [[ "$prev" == on-demand ]]; then
          ok "prime-select on-demand"
        else
          runcmd prime-select on-demand
          BOOT_CHANGED=1
        fi
      else
        warn "prime-select not found (package nvidia-prime)"
      fi
      for u in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service; do
        unit_exists "$u" || continue
        if [[ "$(unit_enabled_state "$u")" == enabled ]]; then
          info "enabled    $u"
        else
          (( DRY_RUN )) || record_unit "$u"
          runcmd_ok systemctl enable "$u"
        fi
      done
      ;;
    amd)
      dev="$SYS/bus/pci/devices/$DGPU_PCI"
      ctl=$(read_sys "$dev/power/control")
      if [[ "$ctl" == auto ]]; then
        ok "amdgpu runtime PM active (power/control=auto)"
      else
        warn "AMD dGPU power/control=${ctl:-unknown} (expected auto) — check amdgpu.runpm"
      fi
      info "Run a program on the dGPU with: DRI_PRIME=1 <command>"
      ;;
    "")
      info "no discrete GPU"
      ;;
    *)
      warn "dGPU vendor $DGPU_VENDOR: no specific configuration"
      ;;
  esac
}

# emit DEST MODE RENDER_FUNCTION... — write a generated file
emit() {
  local dest="$1"
  PRODUCED+=("$dest")
  write_rendered "$@" || true
}

# emit_copy SRC DEST MODE — install a file from the source tree
emit_copy() {
  PRODUCED+=("$2")
  install_content "$2" "$3" "$1" || true
}

self_install() {
  local f rel
  SHOW_CONTENT=0
  emit_copy "$BO_HOME/battery-optimizer" "$LIB_INSTALL_DIR/battery-optimizer" 0755
  emit_copy "$BO_HOME/VERSION" "$LIB_INSTALL_DIR/VERSION" 0644
  emit_copy "$BO_HOME/hook/profile-hook" "$LIB_INSTALL_DIR/hook/profile-hook" 0755
  emit_copy "$BO_HOME/config/profiles.conf" "$LIB_INSTALL_DIR/config/profiles.conf" 0644
  for f in "$BO_HOME"/lib/*.sh "$BO_HOME"/templates/*; do
    rel="${f#"$BO_HOME"/}"
    emit_copy "$f" "$LIB_INSTALL_DIR/$rel" 0644
  done
  emit "$CLI_INSTALL_PATH" 0755 render_cli_wrapper
  SHOW_CONTENT=1
}

render_cli_wrapper() {
  printf '#!/bin/sh\n# Installed by battery-optimizer %s\nexec %s/battery-optimizer "$@"\n' \
    "$BO_VERSION" "$LIB_INSTALL_DIR"
}

# remove_tracked PATH — delete a manifest file (backing it up if edited)
remove_tracked() {
  local f="$1" target
  target=$(p "$f")
  if [[ -f "$target" ]]; then
    if [[ "$(sha256_of "$target")" != "$(manifest_get file "$f" || true)" ]]; then
      backup_file "$f"
      warn "$f was modified — saved to $BACKUP_LAST"
    fi
    runcmd rm -f "$target"
    info "removed    $f"
  fi
  if is_boot_file "$f"; then
    BOOT_CHANGED=1
    [[ "$f" == /etc/default/grub* ]] && GRUB_CHANGED=1
  fi
  (( DRY_RUN )) || manifest_del file "$f"
}

step_files() {
  PRODUCED=()
  emit "$TLP_DROPIN" 0644 render_tlp_dropin
  emit "$HOOK_CONF" 0644 render_hook_conf
  emit "$HOOK_UNIT" 0644 render_hook_unit
  emit "$UDEV_RULES" 0644 render_udev_rules
  if [[ "$DGPU_VENDOR" == nvidia ]]; then
    emit "$MODPROBE_DROPIN" 0644 render_nvidia_modprobe
  fi
  self_install

  # files from an earlier install that this one no longer produces
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ " ${PRODUCED[*]} " == *" $f "* ]] || remove_tracked "$f"
  done < <(manifest_keys file)

  for f in "${CHANGED_FILES[@]}"; do
    if is_boot_file "$f"; then
      BOOT_CHANGED=1
      [[ "$f" == /etc/default/grub* ]] && GRUB_CHANGED=1
    fi
  done
  return 0
}

step_services() {
  local u
  # Only TLP configures power settings
  if [[ "$CPU_VENDOR" == intel ]]; then
    if [[ "$(unit_enabled_state thermald.service)" == enabled ]]; then
      info "enabled    thermald.service"
    else
      (( DRY_RUN )) || record_unit thermald.service
      runcmd_ok systemctl enable --now thermald.service
    fi
  fi
  for u in tuned.service power-profiles-daemon.service; do
    unit_exists "$u" || continue
    case "$(unit_enabled_state "$u")" in
      masked) info "masked     $u" ;;
      *)
        (( DRY_RUN )) || record_unit "$u"
        runcmd_ok systemctl disable --now "$u"
        runcmd_ok systemctl mask "$u"
        ;;
    esac
  done
  if unit_exists laptop-mode.service; then
    warn "laptop-mode-tools is installed and conflicts with TLP — consider: sudo apt remove laptop-mode-tools"
  fi

  runcmd_ok systemctl daemon-reload
  runcmd_ok udevadm control --reload-rules
  # our own units: removed with their package/file on uninstall
  for u in tlp.service tlp-pd.service "$HOOK_UNIT_NAME"; do
    runcmd_ok systemctl enable "$u"
  done
  runcmd_ok systemctl restart tlp-pd.service
  runcmd_ok systemctl restart "$HOOK_UNIT_NAME"
  runcmd_ok tlp start
}

step_rebuild_boot() {
  local need_initramfs=0 f
  (( MIGRATE_BOOT_CHANGED )) && need_initramfs=1
  for f in "${CHANGED_FILES[@]}"; do
    [[ "$f" == /etc/modprobe.d/* ]] && need_initramfs=1
  done
  (( MIGRATE_GRUB )) && GRUB_CHANGED=1
  if (( need_initramfs )); then
    runcmd update-initramfs -u
    BOOT_CHANGED=1
  fi
  if (( GRUB_CHANGED )); then
    runcmd update-grub
    BOOT_CHANGED=1
  fi
  (( need_initramfs || GRUB_CHANGED )) || ok "no boot-time changes"
  return 0
}

# ---------------------------------------------------------------- uninstall

uninstall_all() {
  local keep_ppa="$1" f u prev hook="$LIB_INSTALL_DIR/hook/profile-hook"
  local apt_args=() p need_initramfs=0

  section "Profile hook"
  if [[ -x "$(p "$hook")" ]] && have python3 && [[ -z "$ROOT" ]]; then
    runcmd_ok python3 -I "$hook" --restore --config "$HOOK_CONF" --state-dir "$VAR_DIR"
  fi
  runcmd_ok systemctl disable --now "$HOOK_UNIT_NAME"

  section "Files"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ "$f" == /etc/modprobe.d/* ]] && need_initramfs=1
    remove_tracked "$f"
  done < <(manifest_keys file)
  runcmd rm -f "$(p "$VAR_DIR/state.json")"

  section "Services and packages"
  # unmask first so reinstalled packages can enable their units
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    [[ "$(manifest_get svc "$u")" == masked ]] && continue
    [[ "$(unit_enabled_state "$u")" == masked ]] && runcmd_ok systemctl unmask "$u"
  done < <(manifest_keys svc)

  while IFS= read -r p; do [[ -n "$p" ]] && apt_args+=("$p"); done < <(manifest_keys pkg-del)
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    case "$p" in
      python3-gi|thermald) ;;  # harmless, often needed by other software
      *) apt_args+=("$p-") ;;
    esac
  done < <(manifest_keys pkg-add)
  if (( ${#apt_args[@]} )); then
    runcmd apt-get install "${APT_OPTS[@]}" --purge "${apt_args[@]}"
  fi

  # restore the original enablement (and running state) of units we changed
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    prev=$(manifest_get svc "$u")
    if (( DRY_RUN )) || unit_exists "$u"; then
      case "$prev" in
        enabled)  runcmd_ok systemctl enable --now "$u" ;;
        disabled) runcmd_ok systemctl disable --now "$u" ;;
        masked)   runcmd_ok systemctl mask "$u" ;;
      esac
    fi
    (( DRY_RUN )) || manifest_del svc "$u"
  done < <(manifest_keys svc)

  if manifest_has ppa "$TLP_PPA"; then
    if (( keep_ppa )); then
      info "keeping ppa:$TLP_PPA (--keep-ppa)"
    else
      runcmd_ok add-apt-repository -y --remove "ppa:$TLP_PPA"
    fi
  fi

  prev=$(manifest_get prime - 2>/dev/null || true)
  if [[ -n "$prev" && "$prev" != unknown ]] && have prime-select \
     && [[ "$(prime-select query 2>/dev/null || true)" != "$prev" ]]; then
    runcmd prime-select "$prev"
    BOOT_CHANGED=1
  fi

  runcmd_ok systemctl daemon-reload
  runcmd_ok udevadm control --reload-rules

  section "Boot files"
  if (( need_initramfs )); then runcmd update-initramfs -u; BOOT_CHANGED=1; fi
  if (( GRUB_CHANGED )); then runcmd update-grub; fi
  (( need_initramfs || GRUB_CHANGED )) || ok "no boot-time changes"

  runcmd rm -f "$(p "$MANIFEST")"
  for f in "$LIB_INSTALL_DIR/templates" "$LIB_INSTALL_DIR/lib" "$LIB_INSTALL_DIR/hook" \
           "$LIB_INSTALL_DIR/config" "$LIB_INSTALL_DIR" "$VAR_DIR" "$STATE_DIR"; do
    [[ -d "$(p "$f")" ]] && runcmd_ok rmdir --ignore-fail-on-non-empty "$(p "$f")"
  done
  return 0
}

# ---------------------------------------------------------------- measure

measure_draw() {
  local minutes="$1" interval="$2" samples i bat w sum status total=0 n=0 min="" max="" profile
  samples=$(( minutes * 60 / interval ))
  (( samples > 0 )) || samples=1

  for bat in "${BATTERIES[@]}"; do
    status=$(read_sys "$SYS/class/power_supply/$bat/status")
    [[ "$status" == Discharging ]] || die "$bat is '$status' — unplug the charger first (see PRD §9)"
  done
  profile=$(active_profile)
  info "Profile: ${profile:-unknown} — sampling every ${interval}s for ${minutes} min (${samples} samples)"
  info "Keep the workload steady; Ctrl-C to abort."

  for (( i = 1; i <= samples; i++ )); do
    sum=0
    for bat in "${BATTERIES[@]}"; do
      status=$(read_sys "$SYS/class/power_supply/$bat/status")
      [[ "$status" == Discharging ]] || die "charger connected during measurement — aborted"
      w=$(battery_watts "$SYS/class/power_supply/$bat")
      [[ -n "$w" ]] || die "$bat reports no power_now/current_now"
      sum=$(awk -v a="$sum" -v b="$w" 'BEGIN { printf "%.2f", a + b }')
    done
    total=$(awk -v a="$total" -v b="$sum" 'BEGIN { printf "%.4f", a + b }')
    n=$i
    if [[ -z "$min" ]] || awk -v a="$sum" -v b="$min" 'BEGIN { exit !(a < b) }'; then min=$sum; fi
    if [[ -z "$max" ]] || awk -v a="$sum" -v b="$max" 'BEGIN { exit !(a > b) }'; then max=$sum; fi
    if [[ -t 1 ]]; then printf '\r  sample %d/%d: %s W   ' "$i" "$samples" "$sum"; fi
    (( i < samples )) && sleep "$interval"
  done
  [[ -t 1 ]] && printf '\n'

  local mean energy_full=0 energy_now=0 e
  mean=$(awk -v t="$total" -v n="$n" 'BEGIN { printf "%.2f", t / n }')
  for bat in "${BATTERIES[@]}"; do
    e=$(read_sys "$SYS/class/power_supply/$bat/energy_full"); [[ "$e" =~ ^[0-9]+$ ]] && energy_full=$((energy_full + e))
    e=$(read_sys "$SYS/class/power_supply/$bat/energy_now");  [[ "$e" =~ ^[0-9]+$ ]] && energy_now=$((energy_now + e))
  done
  printf '\n  Mean draw: %s W  (min %s, max %s, %d samples, profile %s)\n' \
    "$mean" "$min" "$max" "$n" "${profile:-unknown}"
  if (( energy_full > 0 )); then
    awk -v ef="$energy_full" -v en="$energy_now" -v m="$mean" 'BEGIN {
      if (m <= 0) exit
      printf "  Runtime at this draw: %.1f h from full (%.1f Wh), %.1f h remaining (%.1f Wh)\n",
        ef / 1e6 / m, ef / 1e6, en / 1e6 / m, en / 1e6 }'
  fi
}
