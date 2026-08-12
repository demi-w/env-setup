# Setup Script

This is a helper script that automatically installs my dev environment to a new device.
Works on **macOS** and **Linux** (Homebrew on Linux is supported).

Run via:

```bash
bash <(curl -sS https://raw.githubusercontent.com/demi-w/env-setup/refs/heads/main/main.sh)
```

> **Use `bash`, not `sh`.** The script uses bash features (arrays), and on Linux
> `/bin/sh` is dash, which fails to parse it (`Syntax error: "(" unexpected`).
> On macOS `sh` happens to be bash, but `bash` is correct on both platforms.

macOS-only steps (system preferences, Dock, default-browser handling, etc.)
are skipped automatically when running on Linux.
