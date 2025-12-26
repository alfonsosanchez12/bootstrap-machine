#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config
# -----------------------------
PROFILE="${PROFILE:-auto}" # auto|desktop|server
DRY_RUN="${DRY_RUN:-0}"    # 1 = no changes, just print

# Zinit location matches your zsh setup
ZINIT_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git"

# ezpodman install (as provided)
EZPODMAN_URL="https://raw.githubusercontent.com/alfonsosanchez12/ezpodman/main/ezpodman"
EZPODMAN_BIN="$HOME/.local/bin/ezpodman"

# -----------------------------
# Helpers
# -----------------------------
log() { printf "\033[1;34m[bootstrap]\033[0m %s\n" "$*"; }
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

need_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo ""
  else
    echo "sudo"
  fi
}

is_headless_linux() {
  # Heuristic: no GUI env vars, and systemd present often implies server-ish
  [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]
}

detect_os() {
  if [[ "$OSTYPE" == darwin* ]]; then
    echo "macos"
    return
  fi
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
    fedora) echo "fedora" ;;
    arch) echo "arch" ;;
    *) echo "linux-unknown" ;;
    esac
    return
  fi
  echo "unknown"
}

detect_profile() {
  local os="$1"
  if [[ "$PROFILE" != "auto" ]]; then
    echo "$PROFILE"
    return
  fi

  if [[ "$os" == "macos" ]]; then
    echo "desktop"
    return
  fi

  if is_headless_linux; then
    echo "server"
  else
    echo "desktop"
  fi
}

ensure_shell_in_etc_shells() {
  local shell_path="$1"
  local SUDO
  SUDO="$(need_sudo)"

  [[ -x "$shell_path" ]] || return 0

  if [[ -f /etc/shells ]]; then
    if ! grep -qxF "$shell_path" /etc/shells 2>/dev/null; then
      log "Adding $shell_path to /etc/shells"
      run "$SUDO sh -c 'echo \"$shell_path\" >> /etc/shells'"
    fi
  fi
}

set_default_shell() {
  local shell_path="$1"

  if [[ -z "${SHELL:-}" ]]; then
    warn "SHELL env var not set; skipping default shell change"
    return 0
  fi

  if [[ "$SHELL" == "$shell_path" ]]; then
    log "Default shell already set to $shell_path"
    return 0
  fi

  if ! [[ -x "$shell_path" ]]; then
    warn "Shell not executable: $shell_path (skipping)"
    return 0
  fi

  # chsh typically requires a TTY/password; in CI you’d do this via Ansible user module instead.
  if hascmd chsh; then
    log "Setting default shell to $shell_path (may prompt for password)"
    run "chsh -s \"$shell_path\""
  else
    warn "chsh not found; skipping default shell change"
  fi
}

# -----------------------------
# Package manager wrappers
# -----------------------------
brew_ensure() {
  if ! hascmd brew; then
    err "Homebrew not found. Install it first, then re-run. (You said: prefer brew on macOS.)"
    err "Homebrew install docs: https://docs.brew.sh/Installation"
    exit 1
  fi
}

brew_install_formula() {
  local name="$1"
  if brew list --formula "$name" >/dev/null 2>&1; then
    log "brew: $name already installed"
  else
    log "brew: installing formula $name"
    run "brew install \"$name\""
  fi
}

brew_install_cask() {
  local name="$1"
  if brew list --cask "$name" >/dev/null 2>&1; then
    log "brew: $name (cask) already installed"
  else
    log "brew: installing cask $name"
    run "brew install --cask \"$name\""
  fi
}

dnf_install_pkg() {
  local pkg="$1"
  local SUDO
  SUDO="$(need_sudo)"
  if rpm -q "$pkg" >/dev/null 2>&1; then
    log "dnf: $pkg already installed"
    return 0
  fi
  log "dnf: installing $pkg"
  $SUDO dnf install -y "$pkg"
}

pacman_install_pkg() {
  local pkg="$1"
  local SUDO
  SUDO="$(need_sudo)"
  if pacman -Qi "$pkg" >/dev/null 2>&1; then
    log "pacman: $pkg already installed"
  else
    log "pacman: installing $pkg"
    run "$SUDO pacman -S --noconfirm \"$pkg\""
  fi
}

# -----------------------------
# Special installs
# -----------------------------
install_zinit() {
  if [[ -d "$ZINIT_HOME" ]]; then
    log "zinit already present at $ZINIT_HOME"
    return
  fi
  log "Installing zinit (git clone) -> $ZINIT_HOME"
  run "mkdir -p \"$(dirname "$ZINIT_HOME")\""
  run "git clone https://github.com/zdharma-continuum/zinit.git \"$ZINIT_HOME\""
}

install_lazyvim_starter() {
  local nvim_dir="$HOME/.config/nvim"
  if [[ -d "$nvim_dir" ]]; then
    log "LazyVim: $nvim_dir already exists, skipping"
    return
  fi
  log "LazyVim: cloning starter into $nvim_dir"
  run "git clone https://github.com/LazyVim/starter \"$nvim_dir\""
  run "rm -rf \"$nvim_dir/.git\""
  log "LazyVim: installed. First run: nvim (it will install plugins)."
}

install_ezpodman() {
  if [[ -x "$EZPODMAN_BIN" ]]; then
    log "ezpodman already installed at $EZPODMAN_BIN"
    return
  fi
  log "Installing ezpodman -> $EZPODMAN_BIN"
  run "mkdir -p \"$(dirname "$EZPODMAN_BIN")\""
  run "curl -fsSL \"$EZPODMAN_URL\" -o \"$EZPODMAN_BIN\""
  run "chmod +x \"$EZPODMAN_BIN\""
}

install_eza_fedora_git() {
  # Fedora 42+ removed eza from official repos :contentReference[oaicite:9]{index=9}
  if hascmd eza; then
    log "eza already available (command exists), skipping build"
    return
  fi

  local SUDO
  SUDO="$(need_sudo)"
  log "Fedora: installing eza from git via cargo (because repo may not have it)"
  dnf_install_pkg git
  dnf_install_pkg cargo
  dnf_install_pkg rust

  # Install from git (latest)
  # Cargo installs to ~/.cargo/bin; ensure it's in PATH in your shell config if needed.
  run "cargo install --git https://github.com/eza-community/eza --locked"
  log "eza installed via cargo. If 'eza' not found, add ~/.cargo/bin to PATH."
}

fedora_enable_copr() {
  local copr="$1"
  local SUDO
  SUDO="$(need_sudo)"

  # Ensure copr command exists
  if ! dnf copr --help >/dev/null 2>&1; then
    # dnf4: dnf-plugins-core usually provides copr
    # dnf5: copr is provided as a dnf command too, often via plugins package
    warn "dnf copr not available; trying to install dnf plugins"
    run "$SUDO dnf install -y dnf-plugins-core || true"
    # if still not available, we’ll fail when enabling (and print a clear error)
  fi

  log "Fedora: enabling COPR $copr"
  run "$SUDO dnf -y copr enable \"$copr\""
}

install_lazydocker_fedora() {
  # COPR provides lazydocker :contentReference[oaicite:10]{index=10}
  if hascmd lazydocker; then
    log "lazydocker already installed"
    return
  fi
  fedora_enable_copr "atim/lazydocker"
  dnf_install_pkg lazydocker
}

install_ghostty_fedora() {
  # Fedora Magazine shows pgdev/ghostty COPR :contentReference[oaicite:11]{index=11}
  if hascmd ghostty; then
    log "ghostty already installed"
    return
  fi
  fedora_enable_copr "pgdev/ghostty"
  dnf_install_pkg ghostty
}

install_yazi_fedora() {
  if hascmd yazi; then
    log "yazi already installed"
    return
  fi

  # Try official repos first; if install fails, fall back to COPR.
  if dnf_install_pkg yazi 2>/dev/null; then
    return
  fi

  warn "yazi not available in current Fedora repos; enabling COPR lihaohong/yazi"
  # Ensure COPR command exists (per Yazi docs)
  run "$(need_sudo) dnf install -y dnf-plugins-core" # :contentReference[oaicite:3]{index=3}
  fedora_enable_copr "lihaohong/yazi"                # :contentReference[oaicite:4]{index=4}
  dnf_install_pkg yazi
}

install_tailscale_fedora() {
  local SUDO
  SUDO="$(need_sudo)"
  if hascmd tailscale; then
    log "tailscale already installed"
    return 0
  fi

  # 1) Prefer Fedora repos first (matches your preference)
  log "Fedora: trying tailscale from Fedora repos"
  if $SUDO dnf install -y tailscale; then
    log "Fedora: installed tailscale from Fedora repos"
    return 0
  fi

  # 2) Fallback: Tailscale official repo (generic Fedora repo file)
  warn "Fedora repos did not provide tailscale; using Tailscale official repo"
  $SUDO dnf install -y 'dnf-command(config-manager)' || $SUDO dnf install -y dnf-plugins-core

  local repo_url="https://pkgs.tailscale.com/stable/fedora/tailscale.repo" # :contentReference[oaicite:2]{index=2}

  # dnf4 vs dnf5 syntax
  if dnf config-manager --help 2>&1 | grep -q -- "--add-repo"; then
    $SUDO dnf config-manager --add-repo "$repo_url"
  else
    $SUDO dnf config-manager addrepo --from-repofile="$repo_url"
  fi

  $SUDO dnf install -y tailscale
}

install_starship_fedora() {
  if hascmd starship; then
    log "starship already installed"
    return
  fi
  fedora_enable_copr "atim/starship"
  dnf_install_pkg starship
}

install_nft-iptables_arch() {
  local SUDO
  SUDO="$(need_sudo)"

  # Ensure nft variant is installed, if not, install it
  if ! pacman -Qi iptables-nft >/dev/null 2>&1; then
    log "Arch: installing iptables-nft (preferred)"
    run "$SUDO pacman -S --noconfirm iptables-nft"
  else
    log "Arch: iptables-nft already installed"
  fi
}

# -----------------------------
# Main install plan
# -----------------------------
main() {
  local os
  os="$(detect_os)"
  local profile
  profile="$(detect_profile "$os")"

  log "Detected OS: $os"
  log "Profile: $profile (set PROFILE=server|desktop or pass PROFILE env var)"

  case "$os" in
  macos)
    brew_ensure

    # Core tools
    brew_install_formula fastfetch
    brew_install_formula fzf
    brew_install_formula zoxide
    brew_install_formula neovim
    brew_install_formula podman
    brew_install_formula stow
    brew_install_formula pass
    brew_install_formula yazi
    brew_install_formula lazydocker # or tap if you want; see docs :contentReference[oaicite:14]{index=14}
    brew_install_formula eza
    brew_install_formula starship
    brew_install_formula bat
    brew_install_formula btop
    brew_install_formula mactop

    # Tailscale: GUI app (cask)
    brew_install_cask tailscale-app # :contentReference[oaicite:15]{index=15}

    # Ghostty only if desktop
    if [[ "$profile" == "desktop" ]]; then
      brew_install_cask ghostty # :contentReference[oaicite:16]{index=16}
    fi

    # zinit, lazyvim, ezpodman
    install_zinit
    install_lazyvim_starter
    install_ezpodman

    log "macOS Podman note: after install, run once: podman machine init && podman machine start" # :contentReference[oaicite:17]{index=17}
    ;;
  fedora)
    # zsh
    dnf_install_pkg zsh
    ensure_shell_in_etc_shells /bin/zsh
    set_default_shell /bin/zsh

    # Core tools
    dnf_install_pkg fastfetch
    dnf_install_pkg git
    dnf_install_pkg fzf
    dnf_install_pkg zoxide
    dnf_install_pkg neovim
    dnf_install_pkg podman
    dnf_install_pkg stow
    dnf_install_pkg pass
    dnf_install_pkg jq
    dnf_install_pkg bat
    dnf_install_pkg btop
    dnf_install_pkg htop

    # eza (only in desktop) special on Fedora 42+ (git+cargo) :contentReference[oaicite:18]{index=18}
    if [[ "$profile" == "desktop" ]]; then
      install_eza_fedora_git
    fi

    # yazi (try repos; else COPR)
    install_yazi_fedora

    # lazydocker via COPR
    install_lazydocker_fedora

    # tailscale via official repo
    install_tailscale_fedora

    # ghostty only if desktop
    if [[ "$profile" == "desktop" ]]; then
      install_ghostty_fedora
    fi

    # incus is in Fedora repos (41+) :contentReference[oaicite:19]{index=19}
    dnf_install_pkg incus

    # zinit, lazyvim, ezpodman
    install_zinit
    install_lazyvim_starter
    install_ezpodman

    # starship for Fedora is in copr "atim/starship"
    install_starship_fedora
    ;;
  arch)
    local SUDO
    SUDO="$(need_sudo)"
    log "Arch: refreshing package database"
    run "$SUDO pacman -Sy --noconfirm"

    # zsh
    pacman_install_pkg zsh
    ensure_shell_in_etc_shells /bin/zsh
    set_default_shell /bin/zsh

    # NFT Ip-Tables
    install_nft-iptables_arch

    # Core tools
    pacman_install_pkg fastfetch
    pacman_install_pkg git
    pacman_install_pkg fzf
    pacman_install_pkg zoxide
    pacman_install_pkg neovim
    pacman_install_pkg podman
    pacman_install_pkg stow
    pacman_install_pkg pass
    pacman_install_pkg jq
    pacman_install_pkg eza
    pacman_install_pkg starship
    pacman_install_pkg bat
    pacman_install_pkg btop
    pacman_install_pkg htop

    # yazi (available in extra) :contentReference[oaicite:20]{index=20}
    pacman_install_pkg yazi

    # lazydocker is in extra :contentReference[oaicite:21]{index=21}
    pacman_install_pkg lazydocker

    # tailscale is in repos; enable service optionally :contentReference[oaicite:22]{index=22}
    pacman_install_pkg tailscale
    log "Arch: enable Tailscale with: $SUDO systemctl enable --now tailscaled (optional)" # :contentReference[oaicite:23]{index=23}

    # ghostty only if desktop (ghostty is in extra) :contentReference[oaicite:24]{index=24}
    if [[ "$profile" == "desktop" ]]; then
      pacman_install_pkg ghostty
    fi

    # incus (ArchWiki says install incus and enable socket) :contentReference[oaicite:25]{index=25}
    # it prefers nft-ip-tables
    pacman_install_pkg incus
    # install_incus_arch
    log "Arch: incus note: enable with: $SUDO systemctl enable --now incus.socket (optional)" # :contentReference[oaicite:26]{index=26}

    # zinit, lazyvim, ezpodman
    install_zinit
    install_lazyvim_starter
    install_ezpodman
    ;;
  *)
    err "Unsupported OS: $os"
    exit 1
    ;;
  esac

  log "Done."
}

main "$@"
