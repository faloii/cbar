#!/usr/bin/env bash
# Build ClaudeBar.app and package it into a distributable .dmg (app + Applications symlink).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ClaudeBar"
APP="build/${APP_NAME}.app"
VERSION="${CLAUDEBAR_VERSION:-$(cat VERSION 2>/dev/null || echo 1.0.0)}"
DMG="build/${APP_NAME}-${VERSION}.dmg"

./Scripts/package_app.sh

echo "==> Building ${DMG}"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "${APP_NAME} ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Done: ${DMG}"
echo "    Drag ClaudeBar into Applications from the mounted disk image."
echo "    (For sharing to other Macs without a Gatekeeper warning, notarize it:"
echo "     re-sign with a Developer ID identity and run Scripts/notarize.sh.)"
