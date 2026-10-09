#!/bin/bash
# Builds and (by default) launches Shellhouse from the command line — no
# Xcode UI needed, PROVIDED you've built once from Xcode after any
# bundle-id/team change so it can create/cache the provisioning profile.
# `xcodebuild` itself has no access to the Apple ID signed into Xcode's own
# Settings > Accounts, so it can't create that profile from a cold start —
# see the chat history for why. If this script fails with a provisioning
# error, that one-time Xcode build is what's missing.
#
# Usage:
#   scripts/build.sh              # build (Debug) and launch
#   scripts/build.sh --no-run     # build only
#   scripts/build.sh --release    # Release configuration
#   scripts/build.sh --install    # also copy the built .app to /Applications
set -euo pipefail

cd "$(dirname "$0")/.."  # macos/

CONFIGURATION="Debug"
SHOULD_RUN=1
SHOULD_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIGURATION="Release" ;;
    --no-run) SHOULD_RUN=0 ;;
    --install) SHOULD_INSTALL=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Building (${CONFIGURATION})"
xcodebuild \
  -project "Shellhouse.xcodeproj" \
  -scheme "Shellhouse" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  build

APP_PATH=$(xcodebuild -project "Shellhouse.xcodeproj" -scheme "Shellhouse" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
  | awk -F'= ' '/ BUILT_PRODUCTS_DIR =/ { print $2; exit }')
APP="$APP_PATH/Shellhouse.app"

if [ "$SHOULD_INSTALL" = "1" ]; then
  INSTALLED="/Applications/Shellhouse.app"
  echo "==> Installing to $INSTALLED"
  # A running copy holds its own executable open on disk even after
  # replacement, so overwriting in place is safe — but quitting first
  # avoids launching a stale-vs-fresh pair of processes side by side.
  osascript -e 'tell application "Shellhouse" to quit' >/dev/null 2>&1 || true
  rm -rf "$INSTALLED"
  cp -R "$APP" "$INSTALLED"
  APP="$INSTALLED"
fi

if [ "$SHOULD_RUN" = "1" ]; then
  echo "==> Launching $APP"
  open "$APP"
else
  echo "==> Built: $APP"
fi
