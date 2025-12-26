#!/usr/bin/env bash
set -euo pipefail

TERMINFO_NAME="${TERMINFO_NAME:-xterm-ghostty}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf "\033[1;34m[terminfo]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[err]\033[0m %s\n" "$*"; }

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

hascmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Install Ghostty terminfo (xterm-ghostty) on a remote via SSH or Incus.

Usage:
  push-ghostty-terminfo.sh ssh  <host> [<host>...]
  push-ghostty-terminfo.sh incus <instance> [<instance>...]
  push-ghostty-terminfo.sh target <ssh:host|incus:instance> [more targets...]

Options:
  DRY_RUN=1                Print actions without executing
  TERMINFO_NAME=...        Default: xterm-ghostty

Examples:
  ./push-ghostty-terminfo.sh ssh fedora01 arch01
  ./push-ghostty-terminfo.sh incus arch01 fedora-vm
  ./push-ghostty-terminfo.sh target ssh:fedora01 incus:arch01

Notes:
  - Must be run from a machine where: infocmp -x xterm-ghostty works.
  - Remote must have 'tic' installed (usually from ncurses/terminfo packages).
EOF
}

require_local_terminfo() {
  if ! hascmd infocmp; then
    err "infocmp not found locally. Install ncurses/terminfo tools."
    exit 1
  fi

  if ! infocmp -x "$TERMINFO_NAME" >/dev/null 2>&1; then
    err "Local machine cannot export terminfo '$TERMINFO_NAME'."
    err "Run this from your Ghostty Mac (or any system where 'infocmp -x $TERMINFO_NAME' works)."
    exit 1
  fi
}

ssh_has_terminfo() {
  local host="$1"
  ssh "$host" "infocmp -x '$TERMINFO_NAME' >/dev/null 2>&1"
}

ssh_has_tic() {
  local host="$1"
  ssh "$host" "command -v tic >/dev/null 2>&1"
}

install_ssh() {
  local host="$1"

  log "SSH target: $host"

  if ssh_has_terminfo "$host"; then
    log "  already has $TERMINFO_NAME"
    return 0
  fi

  if ! ssh_has_tic "$host"; then
    err "  remote '$host' lacks 'tic'. Install ncurses/terminfo tools first."
    err "  Fedora: sudo dnf install -y ncurses"
    err "  Arch:   sudo pacman -S --noconfirm ncurses"
    return 1
  fi

  log "  installing $TERMINFO_NAME"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] infocmp -x $TERMINFO_NAME | ssh $host -- tic -x -"
  else
    infocmp -x "$TERMINFO_NAME" | ssh "$host" -- tic -x -
  fi
}

incus_has_terminfo() {
  local inst="$1"
  incus exec "$inst" -- sh -lc "infocmp -x '$TERMINFO_NAME' >/dev/null 2>&1"
}

incus_has_tic() {
  local inst="$1"
  incus exec "$inst" -- sh -lc "command -v tic >/dev/null 2>&1"
}

install_incus() {
  local inst="$1"

  log "Incus target: $inst"

  if ! hascmd incus; then
    err "incus command not found locally."
    exit 1
  fi

  if incus_has_terminfo "$inst"; then
    log "  already has $TERMINFO_NAME"
    return 0
  fi

  if ! incus_has_tic "$inst"; then
    err "  instance '$inst' lacks 'tic'. Install ncurses/terminfo tools inside the instance first."
    err "  Fedora: dnf install -y ncurses"
    err "  Arch:   pacman -S --noconfirm ncurses"
    return 1
  fi

  log "  installing $TERMINFO_NAME"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] infocmp -x $TERMINFO_NAME | incus exec $inst -- tic -x -"
  else
    infocmp -x "$TERMINFO_NAME" | incus exec "$inst" -- tic -x -
  fi
}

main() {
  [[ $# -ge 2 ]] || {
    usage
    exit 1
  }

  local mode="$1"
  shift

  require_local_terminfo

  case "$mode" in
  -h | --help | help)
    usage
    exit 0
    ;;
  ssh)
    local rc=0
    for host in "$@"; do
      install_ssh "$host" || rc=1
    done
    exit "$rc"
    ;;
  incus)
    local rc=0
    for inst in "$@"; do
      install_incus "$inst" || rc=1
    done
    exit "$rc"
    ;;
  target)
    local rc=0
    for t in "$@"; do
      case "$t" in
      ssh:*) install_ssh "${t#ssh:}" || rc=1 ;;
      incus:*) install_incus "${t#incus:}" || rc=1 ;;
      *)
        warn "Unknown target format: $t (use ssh:HOST or incus:INSTANCE)"
        rc=1
        ;;
      esac
    done
    exit "$rc"
    ;;
  *)
    err "Unknown mode: $mode"
    usage
    exit 1
    ;;
  esac
}

main "$@"
