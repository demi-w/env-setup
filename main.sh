#!/usr/bin/env bash
# macOS dev environment installer — interactive.
#
# Run with no arguments:
#   ./main.sh
#
# Walks you through:
#   1) Pick a starting profile (dev / work / personal / remote / all / custom)
#   2) Optionally toggle individual apps from that selection
#   3) Choose whether to auto-confirm internal prompts
#   4) Runs each installer in order, isolating failures
#
# Idempotent: re-running is safe. A failure in one step logs an error and
# moves on rather than aborting the whole run.

# Intentionally NOT using `set -e` — partial failures must stay isolated.
set -u
set -o pipefail

# This script requires bash (arrays, declare -f, etc.). If it was invoked
# through a POSIX sh that can still parse it (e.g. macOS /bin/sh, which is
# bash in POSIX mode), re-exec under bash. NOTE: dash — Linux's /bin/sh —
# fails at parse time before this guard runs, so the documented invocation
# must be `bash <(curl ...)`, never `sh <(curl ...)`.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

ASSUME_YES=0
LOG_FILE="${TMPDIR:-/tmp}/dev-setup-$(date +%Y%m%d-%H%M%S).log"
FAILED_STEPS=()
SUCCEEDED_STEPS=()
SKIPPED_STEPS=()
SELECTED_APPS=()

# Platform detection — the installer runs on macOS and Linux.
case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  *)      PLATFORM=other ;;
esac

# Profile membership. Edit here to re-categorize an app.
APPS_DEV=(brew nerd_font ripgrep ghostty fish starship git_base gh zed github_mcp pi chrome mac_settings)
APPS_WORK=(slack datadog_mcp git_work)
APPS_PERSONAL=(spotify git_personal)
APPS_REMOTE=(brew ripgrep fish starship git_base gh pi git_personal)

# All known apps. Order matters: dependencies first.
ALL_APPS=(
  brew
  nerd_font
  ripgrep
  ghostty
  fish
  starship
  git_base
  git_work
  git_personal
  gh
  pi
  zed
  github_mcp
  datadog_mcp
  chrome
  slack
  spotify
  mac_settings
)

# Hard-coded constants
DD_SLACK_TEAM_DOMAIN="dd"   # https://dd.slack.com — adjust if your DD workspace uses a different subdomain

# ---------------------------------------------------------------------------
# Logging / helpers
# ---------------------------------------------------------------------------

log()   { printf '\033[1;34m[*]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
ok()    { printf '\033[1;32m[✓]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
err()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
skip()  { printf '\033[1;90m[-]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Locate Homebrew's binary across macOS + Linux install prefixes.
brew_bin_path() {
  if [ -x /opt/homebrew/bin/brew ]; then
    printf '%s\n' /opt/homebrew/bin/brew
  elif [ -x /usr/local/bin/brew ]; then
    printf '%s\n' /usr/local/bin/brew
  elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    printf '%s\n' /home/linuxbrew/.linuxbrew/bin/brew
  elif [ -x "$HOME/.linuxbrew/bin/brew" ]; then
    printf '%s\n' "$HOME/.linuxbrew/bin/brew"
  elif command -v brew >/dev/null 2>&1; then
    command -v brew
  else
    printf '%s\n' ""
  fi
}

# Locate the fish binary across macOS + Linux install prefixes.
fish_bin_path() {
  if [ -x /opt/homebrew/bin/fish ]; then
    printf '%s\n' /opt/homebrew/bin/fish
  elif [ -x /usr/local/bin/fish ]; then
    printf '%s\n' /usr/local/bin/fish
  elif [ -x /home/linuxbrew/.linuxbrew/bin/fish ]; then
    printf '%s\n' /home/linuxbrew/.linuxbrew/bin/fish
  elif [ -x "$HOME/.linuxbrew/bin/fish" ]; then
    printf '%s\n' "$HOME/.linuxbrew/bin/fish"
  elif command -v fish >/dev/null 2>&1; then
    command -v fish
  else
    printf '%s\n' ""
  fi
}

# Cross-platform "open this URL / file in the default handler".
open_browser() {
  local target="$1"
  if [ "$PLATFORM" = "macos" ]; then
    open "$target" 2>/dev/null
  else
    xdg-open "$target" >/dev/null 2>&1
  fi
}

confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  local reply
  printf '\033[1;36m[?]\033[0m %s [y/N] ' "$prompt"
  read -r reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_value() {
  # prompt_value "label" VAR_NAME [default]
  local label="$1" var_name="$2" default="${3:-}"
  local val
  if [ -n "$default" ]; then
    printf '\033[1;36m[?]\033[0m %s [%s]: ' "$label" "$default"
  else
    printf '\033[1;36m[?]\033[0m %s: ' "$label"
  fi
  read -r val
  if [ -z "$val" ] && [ -n "$default" ]; then
    val="$default"
  fi
  printf -v "$var_name" '%s' "$val"
}

open_url() {
  # Prompt y/n, then open URL in the user's default browser.
  # Respects ASSUME_YES via confirm() so unattended runs still open browsers.
  local url="$1"
  if confirm "Open $url in your browser?"; then
    open_browser "$url" || warn "Could not open $url"
  fi
}

run_step() {
  local key="$1" fn="$2"
  log "── $key ──"
  if "$fn"; then
    SUCCEEDED_STEPS+=("$key")
  else
    local rc=$?
    err "$key failed (rc=$rc) — continuing"
    FAILED_STEPS+=("$key")
  fi
}

# Run brew non-interactively: skip auto-update/cleanup and auto-confirm the
# dependency-list prompt (brew reads stdin for the "Press RETURN" confirmation).
brew_install() {
  local pkg="$1" cask_flag="${2:-}"
  local brew_cmd=(env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 NONINTERACTIVE=1 brew)
  if [ "$cask_flag" = "--cask" ]; then
    if brew list --cask --versions "$pkg" >/dev/null 2>&1; then
      skip "$pkg (cask) already installed"
      return 0
    fi
    yes '' | "${brew_cmd[@]}" install --cask "$pkg"
  else
    if brew list --versions "$pkg" >/dev/null 2>&1; then
      skip "$pkg already installed"
      return 0
    fi
    yes '' | "${brew_cmd[@]}" install "$pkg"
  fi
}

append_if_missing() {
  local file="$1" line="$2"
  [ -f "$file" ] || touch "$file"
  if ! grep -Fqx "$line" "$file"; then
    printf '\n%s\n' "$line" >> "$file"
  fi
}

contains() {
  # contains <needle> <items...>
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Install functions
# ---------------------------------------------------------------------------

install_brew() {
  if has_cmd brew; then
    ok "Homebrew already installed at $(command -v brew)"
    return 0
  fi
  log "Installing Homebrew (non-interactive)…"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1

  local brew_bin
  brew_bin=$(brew_bin_path)
  if [ -z "$brew_bin" ]; then
    err "Could not locate brew binary after install"
    return 1
  fi
  eval "$("$brew_bin" shellenv)"
  # macOS shells read .zprofile; Linux shells read .bashrc.
  if [ "$PLATFORM" = "macos" ]; then
    append_if_missing "$HOME/.zprofile" "eval \"\$($brew_bin shellenv)\""
  else
    append_if_missing "$HOME/.bashrc" "eval \"\$($brew_bin shellenv)\""
  fi
  # Fish doesn't read the above — wire shellenv into fish config too.
  local fish_cfg="$HOME/.config/fish/config.fish"
  mkdir -p "$(dirname "$fish_cfg")"
  append_if_missing "$fish_cfg" "$brew_bin shellenv fish | source"
  ok "Homebrew installed"
}

install_nerd_font() {
  has_cmd brew || { err "brew required"; return 1; }
  brew_install font-fira-code-nerd-font --cask
}

install_ripgrep() {
  has_cmd brew || { err "brew required"; return 1; }
  brew_install ripgrep
}

install_ghostty() {
  has_cmd brew || { err "brew required"; return 1; }
  brew_install ghostty --cask
}

install_fish() {
  has_cmd brew || { err "brew required"; return 1; }
  brew_install fish || return 1

  local fish_bin
  fish_bin=$(fish_bin_path)
  if [ -z "$fish_bin" ]; then
    err "Could not locate fish binary after install"
    return 1
  fi

  # macOS chsh refuses shells not listed in /etc/shells.
  if ! grep -Fxq "$fish_bin" /etc/shells 2>/dev/null; then
    log "Adding $fish_bin to /etc/shells (sudo required)…"
    if ! echo "$fish_bin" | sudo tee -a /etc/shells >/dev/null; then
      warn "Could not add fish to /etc/shells — skipping chsh"
      return 0
    fi
  fi

  if [ "$SHELL" = "$fish_bin" ]; then
    skip "fish is already the default shell"
  else
    log "Changing default shell to fish (may prompt for password)…"
    chsh -s "$fish_bin" || warn "chsh failed — run 'chsh -s $fish_bin' manually"
  fi

  # Suppress fish's interactive greeting banner.
  local fish_cfg="$HOME/.config/fish/config.fish"
  mkdir -p "$(dirname "$fish_cfg")"
  append_if_missing "$fish_cfg" "set -U fish_greeting ''"

  # Suppress macOS's "Last login:" banner that login(1) prints before fish starts.
  touch "$HOME/.hushlogin"

  ok "fish ready (open a new terminal to enter it)"
}

install_starship() {
  has_cmd brew || { err "brew required"; return 1; }
  brew_install starship || return 1

  # macOS defaults to zsh; Linux defaults to bash. fish is handled below.
  if [ "$PLATFORM" = "macos" ]; then
    append_if_missing "$HOME/.zshrc" 'eval "$(starship init zsh)"'
  else
    append_if_missing "$HOME/.bashrc" 'eval "$(starship init bash)"'
  fi

  local fish_cfg="$HOME/.config/fish/config.fish"
  if has_cmd fish; then
    mkdir -p "$(dirname "$fish_cfg")"
    append_if_missing "$fish_cfg" 'starship init fish | source'
    # Re-add the pre-prompt newline that add_newline=false disabled, but skip
    # it on the very first prompt so the session opens flush at the top.
    if ! grep -q '_starship_first_prompt_done' "$fish_cfg" 2>/dev/null; then
      # We must capture and restore $status manually: fish leaks the status
      # of a failing `set -q` past the end of an if/else block, which would
      # paint starship's prompt character red on every fresh session.
      cat >> "$fish_cfg" <<'FISH'

functions --copy fish_prompt _starship_inner_prompt
function _starship_restore_status
    return $argv[1]
end
function fish_prompt
    set -l _starship_last_status $status
    if set -q _starship_first_prompt_done
        echo
    else
        set -g _starship_first_prompt_done 1
    end
    _starship_restore_status $_starship_last_status
    _starship_inner_prompt
end
FISH
    fi
  fi

  local cfg="$HOME/.config/starship.toml"
  mkdir -p "$(dirname "$cfg")"
  if [ ! -f "$cfg" ]; then
    log "Fetching gruvbox-rainbow preset…"
    starship preset gruvbox-rainbow -o "$cfg" || warn "Could not write starship preset"
    # Disable starship's pre-prompt newline; fish wrapper below re-adds it for
    # every prompt except the first, so the very first prompt has no blank gap.
    # Insert at the TOP (root level): appending at the end would land inside the
    # final [character] section and trigger an "Unknown key 'add_newline'" warning.
    if ! grep -q '^add_newline' "$cfg" 2>/dev/null; then
      printf 'add_newline = false\n\n' | cat - "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    fi
    # Show the device name where the preset shows $username — devices change
    # more often than users.
    # NOTE: no `-i` flag — BSD sed (macOS) and GNU sed (Linux) parse `-i ''`
    # differently, so we write to a temp file and move it into place instead.
    /usr/bin/sed 's/^\$username\\$/$hostname\\/' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    # Keep the [os] icon flush against the leading orange arrow; the [hostname]
    # module that follows provides the spacing (its format has a leading space).
    /usr/bin/sed 's|^style = "bg:color_orange fg:color_fg0"$|&\
format = '"'"'[$symbol]($style)'"'"'|' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    # Replace the now-unused [username] block with an always-on [hostname] block,
    # styled like the username block it replaces. Runs after the [os] padding sed
    # above so its `style = ...` line isn't mistaken for the [os] one.
    /usr/bin/sed '/^\[username\]$/,/format = .*\$user.*$/c\
[hostname]\
ssh_only = false\
style = "bg:color_orange fg:color_fg0"\
format = '"'"'[ $hostname ]($style)'"'"'
' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  else
    skip "starship.toml already exists — leaving as-is"
  fi
  ok "Starship ready (open a new shell to see it)"
}

install_git_base() {
  has_cmd brew || { err "brew required"; return 1; }
  brew_install git || return 1
  git config --global init.defaultBranch main
  ok "git installed — identity configured by git_work / git_personal"
}

_configure_git_identity() {
  local label="$1" default_email="$2"
  has_cmd git || { err "git not installed"; return 1; }

  local name email
  prompt_value "Git user.name for $label" name "$(git config --global user.name || true)"
  prompt_value "Git user.email for $label" email "$default_email"
  [ -z "$name" ] || git config --global user.name "$name"
  [ -z "$email" ] || git config --global user.email "$email"

  if confirm "Generate or register a GPG signing key for $label?"; then
    has_cmd gpg || brew_install gnupg
    local key_id
    key_id=$(gpg --list-secret-keys --keyid-format=long "$email" 2>/dev/null \
      | awk '/^sec/ {split($2,a,"/"); print a[2]; exit}')
    if [ -z "$key_id" ]; then
      log "No existing GPG key for $email — generating one now (interactive)…"
      gpg --full-generate-key || { warn "GPG keygen aborted"; return 0; }
      key_id=$(gpg --list-secret-keys --keyid-format=long "$email" \
        | awk '/^sec/ {split($2,a,"/"); print a[2]; exit}')
    else
      ok "Found existing GPG key $key_id for $email"
    fi
    if [ -n "$key_id" ]; then
      git config --global user.signingkey "$key_id"
      git config --global commit.gpgsign true
      log "Public key (copy the block below and paste it into the GitHub form):"
      gpg --armor --export "$key_id"
      open_url "https://github.com/settings/gpg/new"
    fi
  fi
}

install_git_work() {
  _configure_git_identity "WORK" "demi.willison@datadoghq.com"
}

install_git_personal() {
  _configure_git_identity "PERSONAL" ""
}

install_gh() {
  has_cmd brew || { err "brew required"; return 1; }
  brew_install gh || return 1
  if gh auth status >/dev/null 2>&1; then
    ok "gh already authenticated"
  else
    log "Launching gh auth login (interactive)…"
    gh auth login || warn "gh auth login did not complete"
  fi
}

install_pi() {
  if has_cmd pi; then
    ok "Pi (coding agent) CLI already installed"
    return 0
  fi
  if has_cmd npm; then
    npm install -g @earendil-works/pi-coding-agent || return 1
    ok "Pi installed via npm"
  elif curl -fsSL https://pi.dev/install.sh | sh; then
    ok "Pi installed via official script"
  else
    err "Need either npm or curl to install Pi"
    return 1
  fi
}

install_zed() {
  has_cmd brew || { err "brew required"; return 1; }
  brew_install zed --cask || return 1

  local zed_cfg="$HOME/.config/zed"
  mkdir -p "$zed_cfg"

  if [ -e "$zed_cfg/settings.json" ]; then
    skip "Zed settings.json already exists — leaving as-is"
    return 0
  fi

  # Zed has no native settings sync (still open as of May 2026 — see
  # github.com/zed-industries/zed/issues/5010). The standard workaround is to
  # check settings.json into a personal dotfiles repo and symlink it in.
  log "Zed has no built-in settings sync. Recommended: keep settings.json in a dotfiles repo."
  local repo
  prompt_value "Dotfiles git repo URL to clone for Zed settings (blank to skip)" repo ""

  if [ -n "$repo" ]; then
    local target="$HOME/.dotfiles"
    if [ ! -d "$target/.git" ]; then
      git clone "$repo" "$target" || warn "Clone failed — falling back to minimal seed"
    else
      ok "Reusing existing $target"
    fi
    # Try a few common layouts.
    local src=""
    local candidate
    for candidate in \
      "$target/zed/settings.json" \
      "$target/.config/zed/settings.json" \
      "$target/config/zed/settings.json" \
      "$target/zed-settings.json"; do
      [ -f "$candidate" ] && src="$candidate" && break
    done
    if [ -n "$src" ]; then
      ln -sf "$src" "$zed_cfg/settings.json"
      ok "Symlinked $zed_cfg/settings.json → $src"
      return 0
    fi
    warn "Could not locate a Zed settings.json inside $target — falling back to minimal seed"
  fi

  # Minimal seed to silence the welcome flow until you wire up dotfiles.
  local fish_program
  fish_program=$(fish_bin_path)
  [ -n "$fish_program" ] || fish_program="/opt/homebrew/bin/fish"
  cat > "$zed_cfg/settings.json" <<JSON
{
  "telemetry": { "diagnostics": false, "metrics": false },
  "buffer_font_family": "FiraCode Nerd Font",
  "terminal": {
    "font_family": "FiraCode Nerd Font",
    "shell": { "program": "$fish_program" }
  }
}
JSON
  ok "Seeded minimal Zed settings.json"
}

install_datadog_mcp() {
  local zed_cfg="$HOME/.config/zed/settings.json"
  if [ ! -e "$zed_cfg" ]; then
    err "Install Zed first (no settings.json found)"
    return 1
  fi
  if grep -q '"Datadog"' "$zed_cfg" 2>/dev/null; then
    skip "Datadog MCP already configured in Zed"
    return 0
  fi
  log "Add the Datadog MCP server via Zed's agent settings UI:"
  log "  Zed → Settings → Agent → MCP Servers → Add"
  open_url "https://docs.datadoghq.com/bits_ai/mcp_server/setup/"
  # Auto-edit skipped intentionally: the auth handshake is a browser flow.
}

install_github_mcp() {
  # Configures GitHub's remote MCP server in read-only mode. The /x/all/readonly
  # endpoint exposes every toolset but server-side filters out write tools, so
  # no client-side allowlist is needed — writes literally aren't reachable.
  local zed_cfg="$HOME/.config/zed/settings.json"
  if [ ! -e "$zed_cfg" ]; then
    err "Install Zed first (no settings.json found)"
    return 1
  fi
  if grep -q 'githubcopilot.com/mcp' "$zed_cfg" 2>/dev/null; then
    skip "GitHub MCP already configured in Zed"
    return 0
  fi

  log "GitHub MCP (read-only) setup:"
  log "  Read-only access is enough — no write permissions needed."
  open_url "https://github.com/settings/personal-access-tokens/new"

  local pat=""
  if [ "$ASSUME_YES" -eq 0 ]; then
    printf '\033[1;36m[?]\033[0m Paste GitHub PAT (input hidden, blank to configure later): '
    read -rs pat
    printf '\n'
  fi

  local block
  if [ -n "$pat" ]; then
    block=$(cat <<EOF
  "github": {
    "url": "https://api.githubcopilot.com/mcp/x/all/readonly",
    "headers": { "Authorization": "Bearer $pat" }
  }
EOF
)
  else
    block=$(cat <<'EOF'
  "github": {
    "url": "https://api.githubcopilot.com/mcp/x/all/readonly",
    "headers": { "Authorization": "Bearer <PASTE_PAT_HERE>" }
  }
EOF
)
  fi

  log "Add this block inside (or create) the \"context_servers\" object in $zed_cfg:"
  printf '%s\n' "$block"
  log "Opening settings.json in Zed…"
  if [ "$PLATFORM" = "macos" ]; then
    open -a "Zed" "$zed_cfg" 2>/dev/null || open "$zed_cfg" 2>/dev/null || true
  else
    log "Edit $zed_cfg manually (or run: zed $zed_cfg)"
    command -v zed >/dev/null 2>&1 && zed "$zed_cfg" >/dev/null 2>&1 || true
  fi
  ok "GitHub MCP block printed — paste into settings.json and save"
}

install_chrome() {
  has_cmd brew || { err "brew required"; return 1; }
  brew_install google-chrome --cask || return 1
  if confirm "Make Chrome the default browser?"; then
    if [ "$PLATFORM" = "macos" ]; then
      open -a "Google Chrome" --args --make-default-browser || true
    else
      xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null \
        || warn "Could not set default browser — set it in your desktop settings"
    fi
  fi
  log "Open Chrome and sign in to sync extensions/settings"
}

install_slack() {
  has_cmd brew || { err "brew required"; return 1; }
  brew_install slack --cask || return 1
  log "Opening the Datadog Slack workspace ($DD_SLACK_TEAM_DOMAIN.slack.com) — sign in with SSO"
  open_browser "https://${DD_SLACK_TEAM_DOMAIN}.slack.com" || true
}

install_spotify() {
  has_cmd brew || { err "brew required"; return 1; }
  brew_install spotify --cask || return 1
  log "Sign in to Spotify with demiwillison@gmail.com once it opens"
}

install_mac_settings() {
  if [ "$PLATFORM" != "macos" ]; then
    skip "macOS system preferences are not applicable on $PLATFORM"
    return 0
  fi
  log "Applying macOS preferences…"

  defaults write NSGlobalDomain AppleInterfaceStyle -string "Dark" 2>/dev/null \
    && ok "Dark mode enabled" \
    || warn "Could not set dark mode"

  defaults write NSGlobalDomain com.apple.trackpad.scaling -float 3.0
  defaults write NSGlobalDomain com.apple.mouse.scaling -float 3.0
  ok "Pointer speeds bumped to 3.0"

  defaults write NSGlobalDomain KeyRepeat -int 2
  defaults write NSGlobalDomain InitialKeyRepeat -int 15

  defaults write com.apple.finder AppleShowAllFiles -bool true
  defaults write com.apple.dock tilesize -int 42

  if confirm "Wipe all default Dock items and start fresh?"; then
    if ! has_cmd dockutil; then
      brew_install dockutil || warn "Couldn't install dockutil"
    fi
    if has_cmd dockutil; then
      dockutil --remove all --no-restart >/dev/null 2>&1 || true
      local app
      for app in "/Applications/Ghostty.app" "/Applications/Google Chrome.app" "/Applications/Zed.app" "/Applications/Slack.app" "/Applications/Spotify.app"; do
        [ -e "$app" ] && dockutil --add "$app" --no-restart >/dev/null 2>&1 || true
      done
      ok "Dock reset"
    fi
  fi
  killall Dock 2>/dev/null || true
  killall Finder 2>/dev/null || true

  if confirm "Move every item currently on the Desktop to ~/Desktop_archive_<timestamp>/?"; then
    local archive="$HOME/Desktop_archive_$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$archive"
    find "$HOME/Desktop" -mindepth 1 -maxdepth 1 -not -name ".DS_Store" -exec mv {} "$archive"/ \; \
      && ok "Desktop cleared into $archive" \
      || warn "Desktop cleanup had issues"
  fi
}

# ---------------------------------------------------------------------------
# Interactive selection
# ---------------------------------------------------------------------------

# Print a labeled list of every app, marking selected ones with [x].
# Reads from the global SELECTED_APPS array.
render_app_table() {
  local i=1 app mark
  for app in "${ALL_APPS[@]}"; do
    if contains "$app" "${SELECTED_APPS[@]+"${SELECTED_APPS[@]}"}"; then
      mark="x"
    else
      mark=" "
    fi
    printf "  [%s] %2d) %s\n" "$mark" "$i" "$app"
    i=$((i + 1))
  done
}

# Toggle a single app in/out of SELECTED_APPS by name.
toggle_app() {
  local target="$1"
  local found=0 app
  local new=()
  for app in "${SELECTED_APPS[@]+"${SELECTED_APPS[@]}"}"; do
    if [ "$app" = "$target" ]; then
      found=1
    else
      new+=("$app")
    fi
  done
  if [ "$found" -eq 0 ]; then
    new+=("$target")
  fi
  SELECTED_APPS=("${new[@]+"${new[@]}"}")
}

# Reorder SELECTED_APPS to match ALL_APPS (dependency) order, deduped.
canonicalize_selection() {
  local ordered=() app
  for app in "${ALL_APPS[@]}"; do
    if contains "$app" "${SELECTED_APPS[@]+"${SELECTED_APPS[@]}"}"; then
      ordered+=("$app")
    fi
  done
  SELECTED_APPS=("${ordered[@]+"${ordered[@]}"}")
}

# Seed SELECTED_APPS from a profile name.
seed_from_profile() {
  local profile="$1" app
  SELECTED_APPS=()
  case "$profile" in
    dev)
      SELECTED_APPS=("${APPS_DEV[@]}")
      ;;
    work)
      for app in "${APPS_DEV[@]}" "${APPS_WORK[@]}"; do SELECTED_APPS+=("$app"); done
      ;;
    personal)
      for app in "${APPS_DEV[@]}" "${APPS_PERSONAL[@]}"; do SELECTED_APPS+=("$app"); done
      ;;
    remote)
      SELECTED_APPS=("${APPS_REMOTE[@]}")
      ;;
    all)
      SELECTED_APPS=("${ALL_APPS[@]}")
      ;;
    custom|*)
      SELECTED_APPS=()
      ;;
  esac
  canonicalize_selection
}

pick_profile() {
  while true; do
    clear
    cat <<'EOF'
╔════════════════════════════╗
║   Dev Setup (macOS/Linux)  ║
╚════════════════════════════╝

Pick a starting profile:

  1) dev       brew, fonts, ghostty, fish, starship, git, gh, zed,
               github MCP (read-only), pi, chrome, mac settings
  2) work      dev + Slack (Datadog), Datadog MCP, work git identity
  3) personal  dev + Spotify, personal git identity
  4) remote    headless SSH box: brew, fish, starship, git, gh, pi, git identity
  5) all       everything
  6) custom    start empty and pick individual apps

  q) quit

EOF
    printf '> '
    local choice
    read -r choice
    case "$choice" in
      1) seed_from_profile dev;      return 0 ;;
      2) seed_from_profile work;     return 0 ;;
      3) seed_from_profile personal; return 0 ;;
      4) seed_from_profile remote;   return 0 ;;
      5) seed_from_profile all;      return 0 ;;
      6) seed_from_profile custom;   return 0 ;;
      q|Q) exit 0 ;;
      *) ;;
    esac
  done
}

customize_selection() {
  while true; do
    clear
    cat <<'EOF'
Toggle apps to include in the run.

  Commands:
    <number>  toggle that app
    a         select all
    n         select none
    d         done — proceed with current selection
    q         quit

EOF
    render_app_table
    printf '\n> '
    local cmd
    read -r cmd
    case "$cmd" in
      d|D) canonicalize_selection; return 0 ;;
      q|Q) exit 0 ;;
      a|A) SELECTED_APPS=("${ALL_APPS[@]}") ;;
      n|N) SELECTED_APPS=() ;;
      ''|*[!0-9]*) ;;
      *)
        if [ "$cmd" -ge 1 ] 2>/dev/null && [ "$cmd" -le "${#ALL_APPS[@]}" ]; then
          toggle_app "${ALL_APPS[$((cmd - 1))]}"
        fi
        ;;
    esac
  done
}

confirm_and_run() {
  clear
  printf "Final selection (in run order):\n\n"
  local app
  for app in "${SELECTED_APPS[@]+"${SELECTED_APPS[@]}"}"; do
    printf "  • %s\n" "$app"
  done
  printf '\n'

  if confirm "Auto-confirm internal prompts during install? (dock wipe, desktop archive, etc.)"; then
    ASSUME_YES=1
  fi

  if ! confirm "Proceed with install?"; then
    log "Aborted by user"
    exit 0
  fi

  log "Logging to $LOG_FILE"

  # Cache sudo credentials once so later steps (Homebrew install, /etc/shells)
  # don't each re-prompt for a password.
  if command -v sudo >/dev/null 2>&1; then
    log "Validating sudo access (one-time password prompt)…"
    sudo -v || warn "sudo unavailable — some steps may fail"
  fi

  for app in "${SELECTED_APPS[@]+"${SELECTED_APPS[@]}"}"; do
    if declare -f "install_$app" >/dev/null; then
      run_step "$app" "install_$app"
    else
      err "No installer defined for '$app' — skipping"
      SKIPPED_STEPS+=("$app")
    fi
  done

  printf '\n──── summary ────\n'
  ok "Succeeded: ${SUCCEEDED_STEPS[*]:-(none)}"
  [ "${#FAILED_STEPS[@]}" -gt 0 ] && err "Failed:    ${FAILED_STEPS[*]}"
  [ "${#SKIPPED_STEPS[@]}" -gt 0 ] && warn "Skipped:   ${SKIPPED_STEPS[*]}"
  log "Full log: $LOG_FILE"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  case "${1:-}" in
    --help|-h)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    "") ;;
    *)
      err "Unknown arg: $1 (this script is interactive — run with no flags)"
      exit 1
      ;;
  esac

  if [ "$PLATFORM" = "other" ]; then
    err "This installer supports macOS and Linux only (uname=$(uname -s))"
    exit 1
  fi

  if [ ! -t 0 ]; then
    err "stdin is not a terminal — this installer is interactive"
    exit 1
  fi

  pick_profile

  # Always offer a customize pass: profiles are a starting point, not a verdict.
  if confirm "Customize this selection further?"; then
    customize_selection
  fi

  if [ "${#SELECTED_APPS[@]}" -eq 0 ]; then
    err "Nothing selected — exiting"
    exit 1
  fi

  confirm_and_run
}

main "$@"
