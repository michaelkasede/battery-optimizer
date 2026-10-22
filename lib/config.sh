# shellcheck shell=bash
# Safe KEY=VALUE parser for config/profiles.conf and hook.conf.
# Files are never sourced: every key must match the allow-list and every value
# its pattern, otherwise parsing fails.

declare -gA CONF=()
declare -ga CONF_KEYS=()

# "key-regex  value-regex" — first match wins
CONF_ALLOW=(
  '^PLATFORM_PROFILE_ON_(AC|BAT|SAV)$                ^(low-power|quiet|cool|balanced|balanced-performance|performance)$'
  '^CPU_ENERGY_PERF_POLICY_ON_(AC|BAT|SAV)$          ^(performance|balance_performance|default|balance_power|power)$'
  '^CPU_(BOOST|HWP_DYN_BOOST)_ON_(AC|BAT|SAV)$       ^[01]$'
  '^CPU_(MIN|MAX)_PERF_ON_(AC|BAT|SAV)$              ^([0-9]|[1-9][0-9]|100)$'
  '^PCIE_ASPM_ON_(AC|BAT)$                           ^(default|performance|powersave|powersupersave)$'
  '^WIFI_PWR_ON_(AC|BAT)$                            ^(on|off)$'
  '^RUNTIME_PM_ON_(AC|BAT)$                          ^(on|auto)$'
  '^RUNTIME_PM_DRIVER_DENYLIST$                      ^[a-z0-9_ ]*$'
  '^SOUND_POWER_SAVE_ON_(AC|BAT)$                    ^([0-9]|[1-9][0-9])$'
  '^USB_AUTOSUSPEND$                                 ^[01]$'
  '^USB_DENYLIST$                                    ^([0-9a-f]{4}:[0-9a-f]{4}( [0-9a-f]{4}:[0-9a-f]{4})*)?$'
  '^CHARGE_(START|STOP)$                             ^([0-9]|[1-9][0-9]|100)$'
  '^MEM_SLEEP_ON_(AC|BAT)$                           ^(s2idle|deep)$'
  '^HOOK_BRIGHTNESS_CAP_PCT$                         ^([0-9]|[1-9][0-9]|100)$'
  '^HOOK_DOCKER$                                     ^(stop|warn|ignore)$'
  '^HOOK_IGPU_MAX_PCT$                               ^([0-9]|[1-9][0-9]|100)$'
  '^HOOK_BACKLIGHT$                                  ^([A-Za-z0-9_:-][A-Za-z0-9_.:-]*)?$'
  '^HOOK_IGPU_PCI$                                   ^([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])?$'
)

# conf_value_pattern KEY — print the value regex for KEY, fail if not allowed
conf_value_pattern() {
  local entry kre vre
  for entry in "${CONF_ALLOW[@]}"; do
    read -r kre vre <<< "$entry"
    if [[ "$1" =~ $kre ]]; then
      printf '%s' "$vre"
      return 0
    fi
  done
  return 1
}

# conf_check_file FILE — refuse world-writable files or files in
# world-writable directories (they could be swapped under a root process)
conf_check_file() {
  local f="$1" dir perms
  [[ -f "$f" ]] || { err "config file not found: $f"; return 1; }
  [[ -L "$f" ]] && { err "refusing symlinked config file: $f"; return 1; }
  perms=$(stat -c '%a' "$f")
  if (( 8#$perms & 8#002 )); then
    err "refusing world-writable config file: $f (run: chmod o-w '$f')"
    return 1
  fi
  dir=$(dirname "$f")
  perms=$(stat -c '%a' "$dir")
  if (( 8#$perms & 8#002 )) && ! (( 8#$perms & 8#1000 )); then
    err "refusing config file in world-writable directory: $dir"
    return 1
  fi
}

# conf_parse FILE — fill CONF / CONF_KEYS; returns 1 on any invalid line
conf_parse() {
  local file="$1" line key val pattern lineno=0 bad=0
  CONF=(); CONF_KEYS=()
  conf_check_file "$file" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    # strip leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      err "$file:$lineno: not a KEY=VALUE line"
      bad=1; continue
    fi
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    if [[ "$val" =~ ^\"([^\"]*)\"$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "$val" == *[\"\'\ \#]* ]]; then
      err "$file:$lineno: unquoted value with spaces, quotes or '#' for $key"
      bad=1; continue
    fi
    if ! pattern=$(conf_value_pattern "$key"); then
      err "$file:$lineno: key not allowed: $key"
      bad=1; continue
    fi
    if [[ ! "$val" =~ $pattern ]]; then
      err "$file:$lineno: invalid value for $key: '$val'"
      bad=1; continue
    fi
    [[ -v "CONF[$key]" ]] || CONF_KEYS+=("$key")
    CONF[$key]="$val"
  done < "$file"
  (( bad == 0 ))
}

# conf_get KEY [DEFAULT]
conf_get() {
  if [[ -v "CONF[$1]" ]]; then
    printf '%s' "${CONF[$1]}"
  else
    printf '%s' "${2:-}"
  fi
}

# conf_set KEY VALUE — validated assignment (used for CLI overrides/detection)
conf_set() {
  local pattern
  pattern=$(conf_value_pattern "$1") || { err "key not allowed: $1"; return 1; }
  [[ "$2" =~ $pattern ]] || { err "invalid value for $1: '$2'"; return 1; }
  [[ -v "CONF[$1]" ]] || CONF_KEYS+=("$1")
  CONF[$1]="$2"
}
