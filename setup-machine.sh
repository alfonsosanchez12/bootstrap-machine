#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------
# setup-machine.sh
#
# Run from anywhere (bootstrap-machine repo can live anywhere).
# Dotfiles repo is always cloned/updated into: ~/dotfiles
#
# Flow:
#   1) Clone/update ~/dotfiles (private repo)
#   2) Run ./bootstrap.sh (same folder as this script)
#   3) Stow selected app packages if the app is installed
# -------------------------------------------------

# ---------------------------
# Config (override via env)
# ---------------------------
DOTFILES_REPO_URL="${DOTFILES_REPO_URL:-git@github.com:alfonsosanchez12/dotfiles.git}"
DOTFILES_DIR="$HOME/dotfiles" # fixed by design

DEFAULT_APPS=(zsh nvim starship bat eza yazi karabiner)

DRY_RUN="${DRY_RUN:-0}"       # 1 = print actions only
FORCE_STOW="${FORCE_STOW:-0}" # 1 = stow --adopt on conflicts (risky)
RESTOW="${RESTOW:-1}"         # 1 = stow --restow

# ---------------------------
# Helpers
# ---------------------------
log() { printf "\033[1;34m[setup]\033[0m %s\n" "$*"; }
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

# ---------------------------
# Bootstrap step (local ./bootstrap.sh)
# ---------------------------
run_bootstrap_local() {
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  local bootstrap="$script_dir/bootstrap.sh"

  if [[ ! -f "$bootstrap" ]]; then
    err "bootstrap.sh not found next to setup-machine.sh"
    err "Expected: $bootstrap"
    exit 1
  fi

  log "Running bootstrap: $bootstrap"
  run "chmod +x \"$bootstrap\""
  run "\"$bootstrap\""
}

# ---------------------------
# Clone/update dotfiles (git assumed present)
# ---------------------------
clone_or_update_dotfiles() {
  if ! hascmd git; then
    err "git not found. (It should exist since you cloned bootstrap-machine.)"
    exit 1
  fi

  if [[ -d "$DOTFILES_DIR/.git" ]]; then
    log "dotfiles already cloned: $DOTFILES_DIR (pulling latest)"
    run "git -C \"$DOTFILES_DIR\" pull --ff-only"
    return 0
  fi

  if [[ -e "$DOTFILES_DIR" && ! -d "$DOTFILES_DIR/.git" ]]; then
    err "$DOTFILES_DIR exists but is not a git repo."
    err "Move it aside (or delete it) then re-run."
    exit 1
  fi

  log "Cloning dotfiles -> $DOTFILES_DIR"
  if ! run "git clone \"$DOTFILES_REPO_URL\" \"$DOTFILES_DIR\""; then
    err "Failed to clone dotfiles repo."
    err "If private: prefer SSH URL and ensure your GitHub SSH key is set up."
    exit 1
  fi
}

# ---------------------------
# Stow helpers
# ---------------------------
ensure_stow_installed() {
  if hascmd stow; then
    log "stow already installed"
    return 0
  fi
  err "stow is not installed. Run bootstrap first (or install stow manually), then re-run."
  exit 1
}

# Map stow package -> command to check for app availability
# If the command isn't present, we skip stowing that package.
app_binary_for() {
  case "$1" in
  zsh) echo "zsh" ;;
  nvim) echo "nvim" ;;
  starship) echo "starship" ;;
  bat) echo "bat" ;;
  eza) echo "eza" ;;
  yazi) echo "yazi" ;;
  karabiner) echo "__karabiner_app__" ;;
  *) echo "" ;;
  esac
}

should_stow_app() {
  local app="$1"

  if [[ ! -d "$DOTFILES_DIR/$app" ]]; then
    warn "Dotfiles package not found: $DOTFILES_DIR/$app (skipping)"
    return 1
  fi

  local bin
  bin="$(app_binary_for "$app")"

  # Unknown mapping? stow anyway.
  if [[ -z "$bin" ]]; then
    warn "Unknown app '$app' (no binary mapping). Stowing anyway."
    return 0
  fi

  # Special "non-command" checks (still cross-platform)
  if [[ "$bin" == "__karabiner_app__" ]]; then
    if [[ -d "/Applications/Karabiner-Elements.app" ]]; then
      return 0
    fi
    warn "App '$app' not installed (missing /Applications/Karabiner-Elements.app) — skipping stow"
    return 1
  fi

  if hascmd "$bin"; then
    return 0
  fi

  warn "App '$app' not installed (missing '$bin') — skipping stow"
  return 1
}

stow_app() {
  local app="$1"
  local flags=()
  [[ "$RESTOW" == "1" ]] && flags+=(--restow)

  # Dry-run to detect conflicts
  log "Stow dry-run: $app"
  if ! stow -n -d "$DOTFILES_DIR" -t "$HOME" "${flags[@]}" "$app" >/dev/null 2>&1; then
    warn "Conflicts detected for '$app'."
    if [[ "$FORCE_STOW" == "1" ]]; then
      warn "FORCE_STOW=1: using --adopt (moves existing files into stow package)."
      flags+=(--adopt)
    else
      err "Refusing to stow '$app' due to conflicts."
      err "Resolve conflicts manually or re-run with FORCE_STOW=1 (be careful)."
      return 1
    fi
  fi

  log "Stowing: $app"
  run "stow -d \"$DOTFILES_DIR\" -t \"$HOME\" ${flags[*]} \"$app\""

  # Convenience: link ~/.zshrc if your zsh package uses ~/.config/zsh/.zshrc
  if [[ "$app" == "zsh" ]]; then
    if [[ -f "$HOME/.config/zsh/.zshrc" && ! -e "$HOME/.zshrc" ]]; then
      log "Creating symlink: ~/.zshrc -> ~/.config/zsh/.zshrc"
      run "ln -s \"$HOME/.config/zsh/.zshrc\" \"$HOME/.zshrc\""
    fi
  fi
}

usage() {
  cat <<EOF
Run local bootstrap.sh + clone private dotfiles into ~/dotfiles + stow app configs.

Usage:
  ./setup-machine.sh --all
  ./setup-machine.sh --apps "zsh nvim starship"
  ./setup-machine.sh --skip-bootstrap
  ./setup-machine.sh --skip-stow

Env overrides:
  DOTFILES_REPO_URL=...   (default: $DOTFILES_REPO_URL)
  DRY_RUN=1
  FORCE_STOW=1
  RESTOW=0

Notes:
  - Dotfiles are always cloned into: $HOME/dotfiles
  - bootstrap.sh must be in the same folder as setup-machine.sh
EOF
}

# ---------------------------
# Main
# ---------------------------
APPS=()
DO_BOOTSTRAP=1
DO_STOW=1

while [[ $# -gt 0 ]]; do
  case "$1" in
  --apps)
    shift
    # shellcheck disable=SC2206
    APPS=($1)
    ;;
  --all)
    APPS=("${DEFAULT_APPS[@]}")
    ;;
  --skip-bootstrap) DO_BOOTSTRAP=0 ;;
  --skip-stow) DO_STOW=0 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    err "Unknown argument: $1"
    usage
    exit 1
    ;;
  esac
  shift
done

if [[ ${#APPS[@]} -eq 0 ]]; then
  APPS=("${DEFAULT_APPS[@]}")
fi

# 1) Dotfiles ready
clone_or_update_dotfiles

# 2) Bootstrap (installs packages, incl. stow)
if [[ "$DO_BOOTSTRAP" == "1" ]]; then
  run_bootstrap_local
else
  log "Skipping bootstrap (--skip-bootstrap)"
fi

# 3) Stow
if [[ "$DO_STOW" == "1" ]]; then
  ensure_stow_installed
  log "Stow apps: ${APPS[*]}"
  rc=0
  for app in "${APPS[@]}"; do
    if should_stow_app "$app"; then
      stow_app "$app" || rc=1
    fi
  done
  exit "$rc"
else
  log "Skipping stow (--skip-stow)"
fi
