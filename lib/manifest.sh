# shellcheck shell=bash
# Manifest of every change the installer makes, so uninstall can undo it.
#
# /etc/battery-optimizer/manifest — tab-separated "TYPE KEY VALUE" lines:
#   file      PATH     sha256 of the content we wrote
#   backup    PATH     where a pre-existing file was moved before we replaced/removed it
#   svc       UNIT     unit state before we changed it (enabled|disabled|masked|static|...)
#   pkg-add   PACKAGE  -   (installed by us)
#   pkg-del   PACKAGE  -   (removed by us or by apt conflicts)
#   ppa       NAME     -   (apt source added by us)
#   prime     -        prime-select mode before install
#   charge    BATTERY  START:END charge thresholds before install (START is - if absent)
#
# In dry-run mode the manifest lives in memory only.

declare -ga MANIFEST_LINES=()

manifest_path() { p "$MANIFEST"; }

manifest_load() {
  MANIFEST_LINES=()
  local f line
  f=$(manifest_path)
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    MANIFEST_LINES+=("$line")
  done < "$f"
}

manifest_save() {
  (( DRY_RUN )) && return 0
  local f tmp
  f=$(manifest_path)
  mkdir -p "$(dirname "$f")"
  tmp=$(mktemp "$f.XXXXXX")
  {
    printf '# battery-optimizer manifest — do not edit (used by uninstall)\n'
    ((${#MANIFEST_LINES[@]})) && printf '%s\n' "${MANIFEST_LINES[@]}"
  } > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$f"
}

# manifest_get TYPE KEY — print VALUE, fail if absent
manifest_get() {
  local line t k v
  for line in "${MANIFEST_LINES[@]}"; do
    IFS=$'\t' read -r t k v <<< "$line"
    if [[ "$t" == "$1" && "$k" == "$2" ]]; then
      printf '%s' "$v"
      return 0
    fi
  done
  return 1
}

manifest_has() { manifest_get "$1" "$2" >/dev/null; }

# manifest_keys TYPE — print all keys of TYPE, one per line, in order
manifest_keys() {
  local line t k v
  for line in "${MANIFEST_LINES[@]}"; do
    IFS=$'\t' read -r t k v <<< "$line"
    [[ "$t" == "$1" ]] && printf '%s\n' "$k"
  done
  return 0
}

# manifest_set TYPE KEY VALUE — add or replace
manifest_set() {
  local i t k v new=()
  local entry
  entry=$(printf '%s\t%s\t%s' "$1" "$2" "${3:--}")
  local replaced=0
  for i in "${!MANIFEST_LINES[@]}"; do
    IFS=$'\t' read -r t k v <<< "${MANIFEST_LINES[$i]}"
    if [[ "$t" == "$1" && "$k" == "$2" ]]; then
      (( replaced )) && continue
      new+=("$entry"); replaced=1
    else
      new+=("${MANIFEST_LINES[$i]}")
    fi
  done
  (( replaced )) || new+=("$entry")
  MANIFEST_LINES=("${new[@]}")
  manifest_save
}

# manifest_set_once TYPE KEY VALUE — record only the first value (prior state)
manifest_set_once() {
  manifest_has "$1" "$2" || manifest_set "$1" "$2" "$3"
}

manifest_del() {
  local i t k v new=()
  for i in "${!MANIFEST_LINES[@]}"; do
    IFS=$'\t' read -r t k v <<< "${MANIFEST_LINES[$i]}"
    [[ "$t" == "$1" && "$k" == "$2" ]] && continue
    new+=("${MANIFEST_LINES[$i]}")
  done
  MANIFEST_LINES=("${new[@]}")
  manifest_save
}

BACKUP_DIR=""
BACKUP_LAST=""

# ensure_backup_dir — create one timestamped backup directory per run
ensure_backup_dir() {
  if [[ -z "$BACKUP_DIR" ]]; then
    BACKUP_DIR="$STATE_DIR/backup-$(timestamp)"
    (( DRY_RUN )) || mkdir -p "$(p "$BACKUP_DIR")"
  fi
}

# backup_file PATH — copy PATH into the backup dir; sets BACKUP_LAST
backup_file() {
  local src="$1"
  BACKUP_LAST=""
  [[ -e "$(p "$src")" || -L "$(p "$src")" ]] || return 0
  ensure_backup_dir
  BACKUP_LAST="$BACKUP_DIR$src"
  if (( DRY_RUN )); then
    info "[dry-run] back up $src -> $BACKUP_LAST"
  else
    mkdir -p "$(dirname "$(p "$BACKUP_LAST")")"
    cp -a "$(p "$src")" "$(p "$BACKUP_LAST")"
  fi
}

declare -ga CHANGED_FILES=()
SHOW_CONTENT=1   # dry-run: print generated content / diffs

# install_content DEST MODE TMPFILE — write TMPFILE to DEST, track in manifest.
# Returns 0 if the file changed, 1 if it was already up to date.
install_content() {
  local dest="$1" mode="$2" src="$3" target new_sum old_sum
  target=$(p "$dest")
  new_sum=$(sha256_of "$src")

  if [[ -f "$target" ]]; then
    old_sum=$(sha256_of "$target")
    if [[ "$old_sum" == "$new_sum" ]]; then
      (( DRY_RUN )) || manifest_set file "$dest" "$new_sum"
      info "unchanged  $dest"
      return 1
    fi
    if ! manifest_has file "$dest"; then
      backup_file "$dest"
      (( DRY_RUN )) || manifest_set_once backup "$dest" "$BACKUP_LAST"
      warn "$dest existed and was not ours — backed up to $BACKUP_LAST"
    elif [[ "$(manifest_get file "$dest")" != "$old_sum" ]]; then
      backup_file "$dest"
      warn "$dest was edited locally — previous version saved to $BACKUP_LAST"
    fi
  fi

  if (( DRY_RUN )); then
    info "[dry-run] write $dest (mode $mode)"
    if (( ! SHOW_CONTENT )); then
      :
    elif [[ -f "$target" ]] && have diff; then
      diff -u "$target" "$src" | sed 's/^/      /' || true
    else
      sed 's/^/      | /' "$src"
    fi
  else
    mkdir -p "$(dirname "$target")"
    install -m "$mode" "$src" "$target"
    if is_root && [[ -z "$ROOT" ]]; then chown root:root "$target"; fi
    manifest_set file "$dest" "$new_sum"
    ok "wrote      $dest"
  fi
  CHANGED_FILES+=("$dest")
  return 0
}

# write_rendered DEST MODE RENDER_FUNCTION [ARGS...]
write_rendered() {
  local dest="$1" mode="$2" tmp rc=0
  shift 2
  tmp=$(mktemp)
  if ! "$@" > "$tmp"; then
    rm -f "$tmp"
    die "failed to render $dest"
  fi
  install_content "$dest" "$mode" "$tmp" || rc=$?
  rm -f "$tmp"
  return $rc
}

# is_boot_file PATH — changing it needs initramfs/GRUB rebuild + reboot
is_boot_file() {
  case "$1" in
    /etc/modprobe.d/*)      return 0 ;;
    /etc/default/grub|/etc/default/grub.d/*) return 0 ;;
  esac
  return 1
}
