#!/usr/bin/env bash
# Cuts a new CBar release: bumps VERSION, commits, tags, and builds the DMG.
# Usage: Scripts/release.sh 1.1.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: Scripts/release.sh <version>   (e.g. 1.1.0)"
    echo "Current version: $(cat VERSION 2>/dev/null || echo unknown)"
    exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must look like X.Y.Z (got: $VERSION)"
    exit 1
fi
TAG="v${VERSION}"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists."
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree isn't clean — commit or stash first."
    git status --short
    exit 1
fi

echo "==> Bumping VERSION: $(cat VERSION 2>/dev/null || echo '(none)') -> ${VERSION}"
echo "$VERSION" > VERSION
git add VERSION
git commit -m "Release ${TAG}"
git tag -a "$TAG" -m "Release ${TAG}"

echo "==> Building CBar-${VERSION}.dmg"
CLAUDEBAR_VERSION="$VERSION" ./Scripts/make_dmg.sh

echo ""
echo "==> Done."
echo "    DMG ready at: build/CBar-${VERSION}.dmg (share directly via Slack/Drive/AirDrop)."
echo ""
echo "    To publish a GitHub Release, just push the tag — the release workflow"
echo "    (.github/workflows/release.yml) builds the DMG and publishes it automatically:"
echo "      git push origin main && git push origin ${TAG}"
echo ""
echo "    Do NOT also run 'gh release create ${TAG}' — that collides with CI's own"
echo "    publish for this tag. CI is the single publish path."
