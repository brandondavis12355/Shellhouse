#!/bin/bash
# One-time setup for running Shellhouse on a Mac that ISN'T the one it was
# built on — self-contained, doesn't need the repo checked out there.
# Copy this file (alongside the .app, or the zip containing it) to the
# target Mac and run it.
#
# What it does, in order:
#   1. Strips the quarantine flag and re-signs the app ad-hoc — see the
#      chat history for why a personal-team "Apple Development" signature
#      gets killed by Gatekeeper on another Mac even after quarantine
#      removal alone. Ad-hoc ("no claimed identity, signed right here")
#      is what Gatekeeper actually trusts as local.
#   2. Moves it into /Applications.
#   3. Installs Ollama if it isn't already (same command as the app's own
#      Settings > Ollama section).
#   4. Generates an SSH key if this Mac doesn't have one yet, and prints
#      it — YOU still have to hand that public key to whoever manages the
#      Linux sandbox host so it gets added to authorized_keys there. This
#      script can't do that part; it's a different machine.
#   5. Launches the app and prints what's still manual (the Keychain
#      secret, the SSH key).
#
# Usage: ./setup-on-target-mac.sh [/path/to/Shellhouse.app]
set -uo pipefail

APP_SRC="${1:-$HOME/Downloads/Shellhouse.app}"
APP_DEST="/Applications/Shellhouse.app"
REMOTE_HOST="${REMOTE_HOST:?set REMOTE_HOST to your Linux host address, e.g. REMOTE_HOST=192.0.2.10 $0}"
REMOTE_USER="${REMOTE_USER:?set REMOTE_USER to your SSH user on that host}"

if [ ! -d "$APP_SRC" ]; then
  echo "Couldn't find an app at: $APP_SRC" >&2
  echo "Usage: $0 [/path/to/Shellhouse.app]" >&2
  exit 1
fi

echo "==> Re-signing (ad-hoc) and clearing quarantine on: $APP_SRC"
xattr -cr "$APP_SRC"
codesign --force --deep -s - "$APP_SRC"
echo "    Note: this drops the app's sandbox entitlements. Not a loss here —"
echo "    an unsandboxed app has no sandbox restriction to hit in the first"
echo "    place, so the SSH tunnel and Keychain access both still work."

if [ "$APP_SRC" != "$APP_DEST" ]; then
  echo "==> Installing to $APP_DEST"
  osascript -e 'tell application "Shellhouse" to quit' >/dev/null 2>&1 || true
  rm -rf "$APP_DEST"
  cp -R "$APP_SRC" "$APP_DEST"
fi

echo "==> Checking for Ollama"
OLLAMA_BIN=""
for candidate in /opt/homebrew/bin/ollama /usr/local/bin/ollama; do
  if [ -x "$candidate" ]; then OLLAMA_BIN="$candidate"; fi
done
if [ -z "$OLLAMA_BIN" ]; then
  echo "    Not found — installing via ollama.com's own script."
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "    Already installed at $OLLAMA_BIN"
fi

echo "==> Checking for an SSH key"
SSH_KEY="$HOME/.ssh/id_ed25519"
if [ ! -f "$SSH_KEY.pub" ]; then
  echo "    None found — generating one (no passphrase, matching how the"
  echo "    app's SSHTunnel expects to connect non-interactively)."
  mkdir -p "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "$(whoami)@$(hostname -s)-shellhouse"
else
  echo "    Found existing key at $SSH_KEY.pub"
fi
ssh-add "$SSH_KEY" >/dev/null 2>&1 || true

echo "==> Launching"
open "$APP_DEST"

cat <<EOF

Done with what this script can do on its own. Two things still need a
human on the OTHER end:

  1. SSH access to the sandbox host ($REMOTE_USER@$REMOTE_HOST):
     Send this Mac's public key to whoever manages that host, to add to
     ~/.ssh/authorized_keys there:

$(cat "$SSH_KEY.pub" | sed 's/^/         /')

  2. In the app itself, once it's open:
     - Settings > Sandbox manager token: paste in the MANAGER_TOKEN value
       from the Linux host's .env (Keychain is per-machine, doesn't sync).
     - Settings > Ollama: pull whichever model(s) you want to use.
EOF
