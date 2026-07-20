#!/usr/bin/env bash
# Build CBar.app and package it into a distributable .dmg (app + Applications
# symlink + a README for recipients on Macs that aren't yours — see below).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="CBar"
APP="build/${APP_NAME}.app"
VERSION="${CLAUDEBAR_VERSION:-$(cat VERSION 2>/dev/null || echo 1.0.0)}"

# Provenance guard: if HEAD isn't exactly the matching release tag (i.e. this is an
# ad-hoc rebuild past a release), tag the DMG name with the short sha so it can't
# silently impersonate the released vX.Y.Z build when shared. Released builds (CI on
# a v* tag, or a clean checkout of the tag) keep the plain CBar-X.Y.Z.dmg name.
DMG_VERSION="$VERSION"
if git rev-parse --git-dir >/dev/null 2>&1; then
    if ! git describe --exact-match --match "v${VERSION}" HEAD >/dev/null 2>&1; then
        SHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
        DIRTY=""
        [ -n "$(git status --porcelain 2>/dev/null)" ] && DIRTY="-dirty"
        DMG_VERSION="${VERSION}-dev.${SHA}${DIRTY}"
    fi
fi
DMG="build/${APP_NAME}-${DMG_VERSION}.dmg"

./Scripts/package_app.sh

echo "==> Building ${DMG}"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Without a Developer ID + notarization, macOS quarantines anything downloaded
# via a browser/Slack/Drive and Gatekeeper blocks the first launch with "cannot
# verify" — not because the app is broken, just unsigned-by-an-identified-
# developer. One-time right-click-Open (or the Terminal command below) clears it
# permanently for that Mac; every launch after that is normal.
cat > "$STAGE/처음 여는 법 (읽어주세요).txt" <<'EOF'
CBar 설치 방법
==============

1. CBar.app을 Applications 폴더로 드래그하세요 (이 창에 보이는 화살표).
2. Applications 폴더에서 CBar를 "더블클릭 대신 마우스 오른쪽 버튼 클릭 → 열기"로
   실행하세요. "확인되지 않은 개발자" 경고가 뜨면 다시 뜬 창에서 "열기"를 누르세요.
   → 이 절차는 처음 한 번만 필요합니다. 그다음부터는 평소처럼 더블클릭하면 됩니다.

   (더블클릭으로 열었는데 "손상되었으므로 열 수 없습니다" 같은 경고만 뜨고 "열기"
   버튼이 없다면, 터미널에서 아래 명령을 한 번 실행한 뒤 다시 열어보세요:
     xattr -cr /Applications/CBar.app
   )

3. 메뉴바 상단에 아이콘이 뜨면 설치 완료입니다. 클릭해서 사용법을 확인하세요.

CBar는 이 Mac에 저장된 Claude Code 사용 기록만 읽습니다 — 계정마다 따로 동작하고
서로의 데이터를 공유하지 않아요. 문의는 만든 사람에게.
EOF

rm -f "$DMG"
hdiutil create -volname "${APP_NAME} ${DMG_VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Done: ${DMG}"
echo "    Share this .dmg (Slack/Drive/AirDrop) — recipients: right-click → Open the"
echo "    first time (Gatekeeper, since this isn't notarized). See the included README."
echo "    (To remove that step entirely, get a Developer ID cert and run Scripts/notarize.sh.)"
