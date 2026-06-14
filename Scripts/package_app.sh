#!/usr/bin/env bash
# Build a distributable ClaudeBar.app bundle (Release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ClaudeBar"
BUNDLE_ID="com.claudebar.app"
BUILD_DIR=".build/release"
APP="build/${APP_NAME}.app"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# App icon (generate if missing).
if [ ! -f Resources/AppIcon.icns ]; then
    echo "==> Generating app icon"
    swift Scripts/make_icon.swift || true
fi
ICON_KEY=""
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key>        <string>AppIcon</string>"
fi

VERSION="${CLAUDEBAR_VERSION:-1.0.0}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
${ICON_KEY}
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Menu-bar-only: no Dock icon, no app-switcher entry. -->
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key> <string>ClaudeBar</string>
</dict>
</plist>
PLIST

# Sign with a STABLE identity so the macOS Keychain "Always Allow" grant for
# reading Claude Code's credentials survives rebuilds. Ad-hoc signatures change
# every build (the requirement is just the cdhash), which makes the keychain
# re-prompt every launch. Prefer Developer ID, then Apple Development.
echo "==> Signing"
SIGN_ID="${CLAUDEBAR_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    for pref in "Developer ID Application" "Apple Development"; do
        # `|| true`: grep exits 1 when a preferred type is absent, which would
        # otherwise trip `set -e`/`pipefail` and abort the script mid-sign.
        SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -Eo "\"${pref}[^\"]*\"" | head -1 | tr -d '"' || true)
        [ -n "$SIGN_ID" ] && break
    done
fi
if [ -n "$SIGN_ID" ]; then
    echo "    identity: $SIGN_ID"
    codesign --force --identifier "$BUNDLE_ID" --sign "$SIGN_ID" "$APP"
    echo "    → stable signature; approve the Keychain prompt once with “Always Allow”."
else
    echo "    no stable identity found — falling back to ad-hoc"
    echo "    (the Keychain will re-prompt after every rebuild; create a signing identity to stop that)"
    codesign --force --identifier "$BUNDLE_ID" --sign - "$APP"
fi

echo "==> Done: ${APP}"
echo "    Install:  cp -r \"${APP}\" /Applications/"
echo "    Run:      open \"${APP}\""
