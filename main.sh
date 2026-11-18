#!/usr/bin/env bash
# Sets up a new macOS or Linux machine. It installs Homebrew, the GitHub CLI and chezmoi,
# signs you in to GitHub, then has chezmoi apply the private dotfiles repo. chezmoi handles
# everything else: packages, dotfiles, macOS settings and commit signing. Safe to re-run.
#   bash <(curl -sS https://raw.githubusercontent.com/demi-w/env-setup/refs/heads/main/main.sh)
set -euo pipefail

DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/demi-w/dotfiles.git}"
log() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }

case "$(uname -s)" in Darwin | Linux) ;; *) echo "macOS and Linux only (for Windows, see the dotfiles README)" >&2; exit 1 ;; esac
[ -t 0 ] || { echo "Run this from a terminal: it signs you in to GitHub and asks a few questions." >&2; exit 1; }

brew_env() {
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    [ -x "$b" ] && { eval "$("$b" shellenv)"; return 0; }
  done
  return 1
}
if ! brew_env; then
  log "Installing Homebrew"
  sudo -v # Homebrew's non-interactive installer needs sudo credentials cached first
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  brew_env
fi

for pkg in gh chezmoi; do
  command -v "$pkg" >/dev/null || HOMEBREW_NO_AUTO_UPDATE=1 brew install "$pkg"
done

# write:ssh_signing_key lets chezmoi register this Mac's commit-signing key without asking again.
if ! gh auth status -h github.com >/dev/null 2>&1; then
  log "Signing in to GitHub"
  gh auth login -h github.com --web --git-protocol https --scopes write:ssh_signing_key
fi
gh auth setup-git -h github.com # git, and so chezmoi, can then clone and pull the private repo

log "Applying dotfiles from $DOTFILES_REPO"
chezmoi init --apply "$DOTFILES_REPO" || {
  echo "chezmoi failed. If GitHub refused the clone, the active gh account may lack access (see: gh auth switch)." >&2
  exit 1
}
