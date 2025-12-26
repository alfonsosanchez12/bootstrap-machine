# bootstrap-machine

Personal, cross-platform machine bootstrap + dotfiles deployment.

This repo is meant to be cloned **anywhere**, then used to:
1) install my base tools (`bootstrap.sh`)
2) clone my private dotfiles repo to `~/dotfiles`
3) stow only the configs that make sense on the current machine (`setup-machine.sh`)

Supported OS:
- macOS (Apple Silicon)
- Fedora (latest)
- Arch (laptop/VM)

---

## What’s inside

- **`bootstrap.sh`**  
  Installs tools (package-manager first, then fallbacks like git/cargo/COPR when needed).

- **`setup-machine.sh`**  
  Orchestrator:
  - clones/updates `~/dotfiles` (private repo; auth required)
  - runs local `./bootstrap.sh`
  - stows selected dotfiles packages based on whether the app exists

---

## Quick start

### 1) Clone this repo (anywhere)

```bash
git clone git@github.com:alfonsosanchez12/bootstrap-machine.git
cd bootstrap-machine
chmod +x bootstrap.sh setup-machine.sh
