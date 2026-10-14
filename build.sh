#!/usr/bin/env bash
# Builds Shellhouse from this checkout, installs it in /Applications and starts it.
#
#   ./build.sh                 # Release build, install, launch
#   ./build.sh --debug         # Debug build instead
#   ./build.sh --team ABCDE12345   # use this Apple signing team (saved to macos/Signing.local.xcconfig)
#   ./build.sh --no-models     # don't install Ollama or pull the default models
#   ./build.sh --no-launch     # install but don't start it
#
# Steps:
#   1. Checks Xcode (installed, license accepted, first-launch components), installs Homebrew if it's missing
#      (its official installer, after you confirm), and installs XcodeGen with it.
#   2. Finds your Apple Development signing team (or asks) and writes macos/Signing.local.xcconfig (git-ignored).
#   3. Generates the Xcode project, builds, and copies "Shellhouse.app" to /Applications (quitting a running copy).
#   4. Installs Ollama with Homebrew if it's missing and pulls the default models (a chat model and a small
#      embedding model for memory search).
#   5. Starts the app and, if ./initial_setup.sh has prepared a Linux host, connects the app to it: authorizes
#      the app's SSH key on the host and imports the host address and manager token.
#
# One-time Xcode setup this needs is in README.md › Building the app.
#
# Drafted with AI assistance (Claude Code); read it before you run it.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "$REPO/scripts/lib/common.sh"

CONFIGURATION="Release"; TEAM_ARG=""; WITH_MODELS=1; LAUNCH=1; ASSUME_YES=0
DEFAULT_MODELS=("qwen2.5:7b-instruct" "nomic-embed-text")
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIGURATION="Debug"; shift ;;
    --team) TEAM_ARG="${2:?--team needs a value}"; shift 2 ;;
    --no-models) WITH_MODELS=0; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done
export ASSUME_YES
MACOS="$REPO/macos"

[ "$(uname -s)" = "Darwin" ] || die "Shellhouse is a Mac app; run this on a Mac."
printf '%sShellhouse — build and install%s\n' "$C_BOLD" "$C_RESET"

# --- 1. Tools --------------------------------------------------------------------------------------------
step "Checking Xcode"
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [ -z "$DEV_DIR" ] || [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  if [ -d /Applications/Xcode.app ]; then
    die "Xcode is installed but the command-line tools point elsewhere. Run:  sudo xcode-select -s /Applications/Xcode.app"
  fi
  die "Xcode is required (the Command Line Tools alone can't build the app). Install it from the App Store, open it once, then run ./build.sh again."
fi
xcodebuild -version >/dev/null 2>&1 || die "xcodebuild doesn't run. Open Xcode once to finish its setup, or run:  sudo xcodebuild -license accept"
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  info "Xcode needs its first-launch components; installing (asks for your password)…"
  sudo xcodebuild -runFirstLaunch || die "Couldn't finish Xcode's first-launch setup. Open Xcode once, then try again."
fi
ok "$(xcodebuild -version | head -1)"

# Homebrew: already on PATH, installed but not on PATH yet (a new shell), or installed now with its official
# installer (https://brew.sh), which asks for your Mac password itself.
ensure_brew() {
  command -v brew >/dev/null && return 0
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then eval "$("$candidate" shellenv)"; return 0; fi
  done
  confirm "Homebrew isn't installed. Shellhouse's build needs it (for XcodeGen and Ollama). Install it now with Homebrew's official installer from brew.sh?" Y "Install Homebrew" "Not now" \
    || die "Homebrew is needed. Install it from https://brew.sh, then run ./build.sh again."
  info "Running Homebrew's installer (it asks for your Mac password and may take a few minutes)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || die "Homebrew's installer didn't finish. See its output above, then run ./build.sh again."
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then eval "$("$candidate" shellenv)"; break; fi
  done
  command -v brew >/dev/null || die "Homebrew installed, but brew isn't found. Open a new Terminal window and run ./build.sh again."
  ok "Installed Homebrew"
}

step "Checking XcodeGen"
if ! command -v xcodegen >/dev/null; then
  ensure_brew
  info "Installing XcodeGen with Homebrew…"
  brew install xcodegen >/dev/null
fi
ok "XcodeGen $(xcodegen --version 2>/dev/null | awk '{print $NF}')"

# --- 2. Signing ------------------------------------------------------------------------------------------
step "Signing"
SIGNING_LOCAL="$MACOS/Signing.local.xcconfig"
current_team() { sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "$SIGNING_LOCAL" 2>/dev/null | head -1; }
# The team ID is the OU of an Apple Development certificate in your keychain.
detect_teams() {
  local tmp; tmp="$(mktemp -d)"
  security find-certificate -a -c "Apple Development" -p > "$tmp/all.pem" 2>/dev/null || true
  awk -v d="$tmp" '/BEGIN CERTIFICATE/{n++} n{print > (d "/c" n ".pem")}' "$tmp/all.pem"
  for f in "$tmp"/c*.pem; do
    [ -f "$f" ] && openssl x509 -in "$f" -noout -subject -nameopt multiline 2>/dev/null
  done | sed -n 's/^[[:space:]]*organizationalUnitName[[:space:]]*=[[:space:]]*\([A-Z0-9]\{10\}\).*/\1/p' | sort -u
  rm -rf "$tmp"
}
TEAM="${TEAM_ARG:-$(current_team)}"
if [ -z "$TEAM" ]; then
  TEAMS="$(detect_teams || true)"
  COUNT="$(printf '%s' "$TEAMS" | grep -c . || true)"
  if [ "$COUNT" = "1" ]; then
    TEAM="$TEAMS"; info "Found your signing team: $TEAM"
  else
    [ "$COUNT" -gt 1 ] && info "Signing teams in your keychain: $(echo $TEAMS)"
    info "Your team ID is in Xcode › Settings › Accounts › (your Apple ID) › team (10 letters and digits)."
    TEAM="$(ask "Apple signing team ID" "$(printf '%s' "$TEAMS" | head -1)")"
  fi
fi
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "\"$TEAM\" isn't a team ID (10 capital letters and digits). See README.md › Building the app."
if [ "$(current_team)" != "$TEAM" ]; then
  printf 'DEVELOPMENT_TEAM = %s\n' "$TEAM" > "$SIGNING_LOCAL"
  ok "Wrote macos/Signing.local.xcconfig (git-ignored)"
else
  ok "Team $TEAM"
fi

# --- 3. Build and install --------------------------------------------------------------------------------
step "Generating the Xcode project"
( cd "$MACOS" && xcodegen generate --quiet )
ok "Shellhouse.xcodeproj"

step "Building ($CONFIGURATION) — the first build takes a few minutes"
DERIVED="$MACOS/.build/xcode"
LOG="$SHELLHOUSE_STATE_DIR/build.log"; mkdir -p "$SHELLHOUSE_STATE_DIR"
if ! ( cd "$MACOS" && xcodebuild -project "Shellhouse.xcodeproj" -scheme "Shellhouse" -configuration "$CONFIGURATION" \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" -allowProvisioningUpdates build ) >"$LOG" 2>&1; then
  grep -E "error:|Provisioning|provisioning profile|No Account|signing" "$LOG" | sort -u | head -15 >&2 || true
  if grep -qiE "provisioning profile|No Account|requires a development team|Signing for" "$LOG"; then
    die "Signing failed. Do the one-time Xcode step in README.md › Building the app (sign in to Xcode with your Apple ID and build once from Xcode), then run ./build.sh again. Full log: $LOG"
  fi
  die "The build failed. Full log: $LOG"
fi
BUILT="$DERIVED/Build/Products/$CONFIGURATION/Shellhouse.app"
[ -d "$BUILT" ] || die "The build finished but there's no app at $BUILT. Full log: $LOG"
ok "Built"

step "Installing to /Applications"
if app_running; then
  osascript -e 'tell application "Shellhouse" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do app_running || break; sleep 0.5; done
  app_running && { pkill -x "Shellhouse" || true; sleep 1; }
fi
rm -rf "$SHELLHOUSE_APP"
ditto "$BUILT" "$SHELLHOUSE_APP"
# Lets Finder and `open` find the new copy's settings file type and shellhouse:// links right away.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$SHELLHOUSE_APP" >/dev/null 2>&1 || true
ok "$SHELLHOUSE_APP"

# --- 4. Models -------------------------------------------------------------------------------------------
if [ "$WITH_MODELS" = "1" ]; then
  step "Local models (Ollama)"
  if ! command -v ollama >/dev/null && [ ! -d /Applications/Ollama.app ]; then
    if confirm "Ollama isn't installed. Install it with Homebrew?" Y; then
      ensure_brew
      brew install ollama >/dev/null && ok "Installed Ollama"
    else
      warn "Skipping models. Install Ollama later (https://ollama.com/download); the app's Settings › Ollama can pull models."
      WITH_MODELS=0
    fi
  fi
fi
if [ "$WITH_MODELS" = "1" ]; then
  OLLAMA="$(command -v ollama || echo /Applications/Ollama.app/Contents/Resources/ollama)"
  # The app starts `ollama serve` itself; start it here too so the pulls can run now.
  if ! curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    ( "$OLLAMA" serve >/dev/null 2>&1 & )
    for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break; sleep 1; done
  fi
  for model in "${DEFAULT_MODELS[@]}"; do
    if "$OLLAMA" list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$model\(:latest\)\?"; then
      ok "$model is already pulled"
    else
      info "Pulling $model…"
      "$OLLAMA" pull "$model" && ok "Pulled $model" || warn "Couldn't pull $model; try again later in the app's Settings › Ollama."
    fi
  done
fi

# --- 5. Launch and connect -------------------------------------------------------------------------------
if [ "$LAUNCH" = "1" ]; then
  step "Starting Shellhouse"
  launch_app && ok "Running" || warn "Couldn't start it; open it from /Applications."
  hand_off_to_app
  ssh_close
fi

step "Done"
load_state
if [ -n "$SHELLHOUSE_HOST" ]; then
  info "Shellhouse is installed and set to use the Linux host $SHELLHOUSE_HOST. Add a bot from the sidebar's + menu."
else
  info "Shellhouse is installed. To give it a Linux host, run ./initial_setup.sh (it connects the app when done)."
fi
