#!/bin/bash
# Renames the Xcode project/branding identifiers from the old "AICompute"
# name to "Shellhouse" — the same edits made by hand in this session, scripted
# so they're repeatable (e.g. reverting and re-applying, or adapting for a
# future rebrand by changing the variables below).
#
# Idempotent: every step is a targeted string replacement of the OLD value,
# so running this again after it's already applied finds nothing to change.
#
# Deliberately NOT touched here (see the chat history for why): SecretStore's
# Keychain service label, RunShellPermissions' UserDefaults key, and a
# DispatchQueue label — all internal-only strings, not Xcode settings, and
# changing them would silently reset saved Keychain/UserDefaults state.
set -euo pipefail

cd "$(dirname "$0")/.."  # macos/

OLD_DISPLAY_NAME="AICompute"
NEW_DISPLAY_NAME="Shellhouse"
OLD_PACKAGE_NAME="AICompute"
NEW_PACKAGE_NAME="Shellhouse"
OLD_BUNDLE_ID="ai.compute.agent"
NEW_BUNDLE_ID="com.shellhouse.app"
OLD_BUNDLE_ID_PREFIX="ai.compute"
NEW_BUNDLE_ID_PREFIX="com.shellhouse"

echo "==> project.yml"
sed -i '' \
  -e "s/^name: ${OLD_DISPLAY_NAME}\$/name: ${NEW_DISPLAY_NAME}/" \
  -e "s/^  ${OLD_DISPLAY_NAME}:\$/  ${NEW_DISPLAY_NAME}:/" \
  -e "s/^  bundleIdPrefix: ${OLD_BUNDLE_ID_PREFIX}\$/  bundleIdPrefix: ${NEW_BUNDLE_ID_PREFIX}/" \
  -e "s/^    ${OLD_PACKAGE_NAME}:\$/    ${NEW_PACKAGE_NAME}:/" \
  -e "s/PRODUCT_BUNDLE_IDENTIFIER: ${OLD_BUNDLE_ID}/PRODUCT_BUNDLE_IDENTIFIER: ${NEW_BUNDLE_ID}/" \
  -e "s/INFOPLIST_KEY_CFBundleDisplayName: \"${OLD_DISPLAY_NAME}\"/INFOPLIST_KEY_CFBundleDisplayName: \"${NEW_DISPLAY_NAME}\"/" \
  -e "s/- package: ${OLD_PACKAGE_NAME}\$/- package: ${NEW_PACKAGE_NAME}/" \
  project.yml

echo "==> Package.swift"
sed -i '' "s/name: \"${OLD_PACKAGE_NAME}\"/name: \"${NEW_PACKAGE_NAME}\"/" Package.swift

echo "==> Resources/AgentApp.entitlements"
sed -i '' "s/\$(AppIdentifierPrefix)${OLD_BUNDLE_ID}/\$(AppIdentifierPrefix)${NEW_BUNDLE_ID}/" Resources/AgentApp.entitlements

echo "==> Regenerating Xcode project"
xcodegen generate

# xcodegen doesn't delete a stale .xcodeproj left over from a previous name.
STALE="${OLD_DISPLAY_NAME}.xcodeproj"
if [ -d "$STALE" ]; then
  echo "==> Removing stale ${STALE}"
  rm -rf "$STALE"
fi

cat <<EOF

Done. Before running the app again:
  1. Build once from Xcode (not just this script) so it re-signs with the
     new bundle id: ${NEW_BUNDLE_ID}
  2. Re-add SANDBOX_MANAGER_TOKEN to Keychain — the old entry lives under
     the old bundle id's access group and will no longer be found.
  3. macOS may re-prompt for the local-network permission on first launch,
     since a new bundle id looks like a different app to it.
EOF
