# Setup Script

Sets up a new **macOS** or **Linux** machine. It installs Homebrew and the GitHub CLI and
signs you in to GitHub. Then it hands off to [chezmoi](https://www.chezmoi.io/), which applies
my private dotfiles repo: packages, shell/git/editor config, macOS settings and commit signing.

```bash
bash <(curl -sS https://raw.githubusercontent.com/demi-w/env-setup/refs/heads/main/main.sh)
```

> **Use `bash`, not `sh`.** On Linux `/bin/sh` is dash, and it can't run this script.

- It's safe to re-run. Anything already installed or signed in is skipped.
- To use a different dotfiles repo, set `DOTFILES_REPO=<git url>`.
- Windows isn't covered. The dotfiles README has the three commands for it.
