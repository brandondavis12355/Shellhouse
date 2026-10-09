#!/bin/bash
# One-time setup for running Shellhouse on a Mac other than the one it was
# built on. Self-contained: copy this file next to the .app (or the zip
# holding it) on the target Mac and run it there.
#
# What it does:
#   1. Clears the quarantine flag and re-signs the app ad-hoc. A personal-team
#      "Apple Development" signature is rejected by Gatekeeper on other Macs
#      even with quarantine removed; an ad-hoc signature made on this Mac is
#      accepted as local.
#   2. Copies it into /Applications and launches it.
#   3. Prints the steps that still happen inside the app.
#
# Usage: ./setup-on-target-mac.sh [/path/to/Shellhouse.app]
set -euo pipefail

APP_SRC="${1:-$HOME/Downloads/Shellhouse.app}"
APP_DEST="/Applications/Shellhouse.app"

if [ ! -d "$APP_SRC" ]; then
  echo "Couldn't find an app at: $APP_SRC" >&2
  echo "Usage: $0 [/path/to/Shellhouse.app]" >&2
  exit 1
fi

echo "==> Re-signing (ad-hoc) and clearing quarantine on: $APP_SRC"
xattr -cr "$APP_SRC"
codesign --force --deep -s - "$APP_SRC"
echo "    Note: an ad-hoc signature drops the app's sandbox entitlements, so"
echo "    this copy runs outside the App Sandbox."

if [ "$APP_SRC" != "$APP_DEST" ]; then
  echo "==> Installing to $APP_DEST"
  osascript -e 'tell application "Shellhouse" to quit' >/dev/null 2>&1 || true
  rm -rf "$APP_DEST"
  cp -R "$APP_SRC" "$APP_DEST"
fi

echo "==> Launching"
open "$APP_DEST"

cat <<'EOF'

Installed. Finish setup in the app's Settings:

  1. Linux host: enter the host and SSH user, press "Copy authorize
     command", run it in Terminal once (it adds the app's own SSH key to
     the host's authorized_keys), then press Test.
  2. Sandbox manager token: paste the MANAGER_TOKEN value from the Linux
     host's ~/shellhouse/.env. Keychain items don't sync between Macs.
  3. Ollama: install it from ollama.com/download (or `brew install ollama`), then
     pull a tool-calling model such as qwen2.5:7b-instruct.
EOF
