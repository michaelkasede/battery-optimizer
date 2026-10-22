# shellcheck shell=bash
# Shared helpers: logging, paths, dry-run execution.
#
# Path prefixes (test-only; unset in normal use):
#   BO_ROOT   prefix for every file the tool reads or writes under / (e.g. /etc)
#   BO_SYSFS  sysfs mount point            (default /sys)
#   BO_PROC   procfs mount point           (default /proc)

ROOT="${BO_ROOT:-}"
SYS="${BO_SYSFS:-/sys}"
PROC="${BO_PROC:-/proc}"

DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}

STATE_DIR="/etc/battery-optimizer"
MANIFEST="$STATE_DIR/manifest"
HOOK_CONF="$STATE_DIR/hook.conf"
VAR_DIR="/var/lib/battery-optimizer"
LIB_INSTALL_DIR="/usr/local/lib/battery-optimizer"
CLI_INSTALL_PATH="/usr/local/sbin/battery-optimizer"

TLP_DROPIN="/etc/tlp.d/50-battery-optimizer.conf"
MODPROBE_DROPIN="/etc/modprobe.d/50-battery-optimizer-nvidia.conf"
UDEV_RULES="/etc/udev/rules.d/80-battery-optimizer.rules"
HOOK_UNIT="/etc/systemd/system/battery-optimizer-hook.service"
HOOK_UNIT_NAME="battery-optimizer-hook.service"

TLP_PPA="linrunner/tlp"
TLP_MIN_VERSION="1.9"

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[1;33m'
  C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_OFF=""
fi

# p PATH — PATH inside the (possibly prefixed) root filesystem
p() { printf '%s%s' "$ROOT" "$1"; }

section() { printf '\n%s== %s%s\n' "$C_BLD$C_BLU" "$*" "$C_OFF"; }
info()    { printf '  %s\n' "$*"; }
ok()      { printf '  %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()    { printf '  %s⚠%s %s\n' "$C_YLW" "$C_OFF" "$*" >&2; }
err()     { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()     { err "$*"; exit 1; }

# runcmd CMD... — execute, or print in dry-run mode
runcmd() {
  if (( DRY_RUN )); then
    printf '  [dry-run] %s\n' "$(quote_cmd "$@")"
  else
    "$@"
  fi
}

# runcmd_ok CMD... — like runcmd, but a failure is reported and ignored
runcmd_ok() {
  runcmd "$@" || warn "command failed (ignored): $(quote_cmd "$@")"
}

quote_cmd() {
  local out="" a
  for a in "$@"; do out+="$(printf '%q' "$a") "; done
  printf '%s' "${out% }"
}

have() { command -v "$1" >/dev/null 2>&1; }

# confirm PROMPT — yes in --yes mode; no when not interactive
confirm() {
  (( ASSUME_YES )) && return 0
  [[ -t 0 ]] || return 1
  local reply
  read -r -p "  $1 [y/N] " reply
  [[ "${reply,,}" == y || "${reply,,}" == yes ]]
}

# read_sys FILE — first line of a sysfs/procfs file, empty if unreadable
read_sys() {
  local line=""
  [[ -r "$1" ]] && { IFS= read -r line < "$1" || true; }
  printf '%s' "$line"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

is_root() { [[ $EUID -eq 0 ]]; }

# Writing to a prefixed test root does not need root.
require_root() {
  (( DRY_RUN )) && return 0
  [[ -n "$ROOT" ]] && return 0
  is_root || die "This command must be run as root: sudo $0 $*"
}

timestamp() { date +%Y%m%d-%H%M%S; }

# version_ge A B — true if version A >= B
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}
