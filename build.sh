#!/usr/bin/env bash
# Builds Shellhouse from this checkout, installs it in /Applications and starts it.
#
#   ./build.sh                 # Release build, install, launch
#   ./build.sh --debug         # Debug build instead
#   ./build.sh --team ABCDE12345   # use this Apple signing team (saved to macos/Signing.local.xcconfig)
#   ./build.sh --no-ollama     # don't install Ollama
#   ./build.sh --no-launch     # install but don't start it
#
# Steps:
#   1. Checks Xcode (installed, license accepted, first-launch components), installs Homebrew if it's missing
#      (its official installer, after you confirm), and installs XcodeGen with it.
#   2. Finds your Apple Development signing team (or asks) and writes macos/Signing.local.xcconfig (git-ignored).
#   3. Generates the Xcode project, builds, and copies "Shellhouse.app" to /Applications (quitting a running copy).
#   4. Installs Ollama with Homebrew if it's missing. It pulls no models: choose them in the app's
#      Settings › Ollama.
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

CONFIGURATION="Release"; TEAM_ARG=""; WITH_OLLAMA=1; LAUNCH=1; ASSUME_YES=0; PREPARE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIGURATION="Debug"; shift ;;
    --team) TEAM_ARG="${2:?--team needs a value}"; shift 2 ;;
    --no-ollama) WITH_OLLAMA=0; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    # Only the Mac's tools and signing (initial_setup.sh does this first, so every question comes up front).
    --prepare-only) PREPARE_ONLY=1; shift ;;
    --no-ui) SHELLHOUSE_UI=0; export SHELLHOUSE_UI; shift ;;
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
# Admin steps (pointing the developer tools at Xcode, accepting its license, its first-launch components) go
# through macOS's own password dialog with the UI, or sudo in Terminal.
as_admin() {
  if ui_on; then
    osascript - "$1" >/dev/null <<'AS'
on run argv
  do shell script (item 1 of argv) with administrator privileges
end run
AS
  else
    sudo /bin/sh -c "$1"
  fi
}
# The Xcode the developer tools already point at (a beta, say), else the first one in /Applications.
find_xcode() {
  local selected; selected="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$selected" == /Applications/Xcode*.app/Contents/Developer ]]; then printf '%s' "${selected%/Contents/Developer}"; return; fi
  ls -d /Applications/Xcode*.app 2>/dev/null | head -1
}
XCODE="$(find_xcode)"
while [ -z "$XCODE" ]; do
  # Xcode only comes from the App Store (or Apple's developer site) with your Apple ID: open its page and wait.
  confirm "Shellhouse is built with Xcode, which isn't installed. It's free from the App Store (about 10 GB). Open its App Store page now? Install it there, then come back here and continue." Y "Open the App Store" "Cancel" \
    || die "Xcode is needed to build the app. Install it from the App Store, then run this again."
  open "macappstore://apps.apple.com/app/id497799835"
  until [ -n "$(find_xcode)" ]; do
    confirm "Waiting for Xcode to finish installing from the App Store. Continue when it's done." Y "It's installed" "Cancel" \
      || die "Stopped while waiting for Xcode."
  done
  XCODE="$(find_xcode)"
done
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
NEEDS=""
[[ "$DEV_DIR" == "$XCODE"* ]] || NEEDS="xcode-select -s '$XCODE/Contents/Developer'; "
DEVELOPER_DIR="$XCODE/Contents/Developer" xcodebuild -license check >/dev/null 2>&1 || NEEDS="$NEEDS'$XCODE/Contents/Developer/usr/bin/xcodebuild' -license accept; "
DEVELOPER_DIR="$XCODE/Contents/Developer" xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || NEEDS="$NEEDS'$XCODE/Contents/Developer/usr/bin/xcodebuild' -runFirstLaunch; "
if [ -n "$NEEDS" ]; then
  info "Finishing Xcode's one-time setup (asks for your Mac password)…"
  as_admin "$NEEDS" || die "Couldn't finish Xcode's setup. Open Xcode once (it offers the same steps), then run this again."
fi
xcodebuild -version >/dev/null 2>&1 || die "xcodebuild still doesn't run. Open Xcode once, then run this again."
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
xcode_signed_in() { defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null | grep -q '@'; }
TEAM="${TEAM_ARG:-$(current_team)}"
if [ -z "$TEAM" ]; then
  TEAMS="$(detect_teams || true)"
  if [ -z "$TEAMS" ] && ! xcode_signed_in; then
    # Signing needs your Apple ID in Xcode (a free account works). Apple doesn't allow that to be scripted.
    open -a "$XCODE"
    until xcode_signed_in; do
      confirm "Sign in to Xcode with your Apple ID (a free one works): in Xcode, choose Settings… › Accounts › + › Apple ID. Continue when you've signed in." Y "I've signed in" "Cancel" \
        || die "Signing in to Xcode is needed to build the app."
    done
    TEAMS="$(detect_teams || true)"
  fi
  COUNT="$(printf '%s' "$TEAMS" | grep -c . || true)"
  if [ "$COUNT" = "1" ]; then
    TEAM="$TEAMS"; ok "Found your signing team"
  elif [ "$COUNT" -gt 1 ] && ui_on && [ "${ASSUME_YES:-0}" != "1" ]; then
    TEAM="$(osascript - $TEAMS <<'AS' 2>/dev/null
on run argv
  set picked to choose from list argv with title "Shellhouse setup" with prompt "Which Apple signing team should the app be signed with?" default items {item 1 of argv}
  if picked is false then return ""
  return item 1 of picked
end run
AS
)"
    [ -n "$TEAM" ] || die "No signing team chosen."
  else
    TEAM="$(ask "Your Apple signing team ID: in Xcode › Settings… › Accounts, select your Apple ID; it's the 10-character Team ID next to your team" "$(printf '%s' "$TEAMS" | head -1)")"
  fi
fi
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "\"$TEAM\" isn't a team ID (10 capital letters and digits). See README.md › Building the app."
if [ "$(current_team)" != "$TEAM" ]; then
  printf 'DEVELOPMENT_TEAM = %s\n' "$TEAM" > "$SIGNING_LOCAL"
  ok "Wrote macos/Signing.local.xcconfig (git-ignored)"
else
  ok "Team $TEAM"
fi

if [ "$PREPARE_ONLY" = "1" ]; then
  # Ollama too, so nothing is left to ask about later.
  if [ "$WITH_OLLAMA" = "1" ] && ! command -v ollama >/dev/null && [ ! -d /Applications/Ollama.app ]; then
    ensure_brew; info "Installing Ollama with Homebrew…"; brew install ollama >/dev/null && ok "Installed Ollama"
  fi
  ok "This Mac has everything it needs to build Shellhouse"
  exit 0
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
    open -a "$XCODE" "$MACOS/Shellhouse.xcodeproj" 2>/dev/null || true
    die "Signing failed. Xcode is open on the project: select the Shellhouse target › Signing & Capabilities, pick your team, press ⌘B once, then run this again. Full log: $LOG"
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

# --- 4. Ollama -------------------------------------------------------------------------------------------
# Only the runtime. No models are pulled: choose and pull them in the app's Settings › Ollama.
if [ "$WITH_OLLAMA" = "1" ] && ! command -v ollama >/dev/null && [ ! -d /Applications/Ollama.app ]; then
  step "Ollama"
  if confirm "Ollama isn't installed. Install it with Homebrew?" Y; then
    ensure_brew
    brew install ollama >/dev/null && ok "Installed Ollama"
  else
    warn "Skipping Ollama. Install it later (https://ollama.com/download)."
  fi
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
