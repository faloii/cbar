#!/usr/bin/env bash
# Build a release ClaudeBar.app and install it into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/ClaudeBar.app"

./Scripts/package_app.sh

echo "==> Installing to ${DEST}"
pkill -x ClaudeBar 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R build/ClaudeBar.app "$DEST"

echo "==> Launching"
open "$DEST"
echo "==> Installed ✓  (set Settings → 일반 → 로그인 시 자동 실행 to start it automatically)"
