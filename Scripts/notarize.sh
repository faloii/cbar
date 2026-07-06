#!/usr/bin/env bash
# Notarize the DMG so other Macs can open it without a Gatekeeper warning.
#
# PREREQUISITES (require a paid Apple Developer account — can't be done with the
# free "Apple Development" certificate):
#   1) A "Developer ID Application" certificate in your keychain. Build the app/DMG
#      signed with it (hardened runtime is added automatically for Developer ID):
#         CLAUDEBAR_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" Scripts/make_dmg.sh
#   2) A notarytool credential profile (one-time):
#         xcrun notarytool store-credentials claudebar-notary \
#           --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Then run this script.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="CBar"
VERSION="${CLAUDEBAR_VERSION:-$(cat VERSION 2>/dev/null || echo 1.0.0)}"
DMG="build/${APP_NAME}-${VERSION}.dmg"
PROFILE="${CLAUDEBAR_NOTARY_PROFILE:-claudebar-notary}"

[ -f "$DMG" ] || { echo "No DMG at ${DMG} — run Scripts/make_dmg.sh first."; exit 1; }

echo "==> Submitting ${DMG} (notarytool profile: ${PROFILE})"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler staple "build/${APP_NAME}.app" || true

echo "==> Notarized & stapled: ${DMG}"
