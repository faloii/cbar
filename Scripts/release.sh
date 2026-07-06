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

echo "==> Bumping VERSION: $(cat VERSION 2>/dev/null || echo '(none)') → ${VERSION}"
echo "$VERSION" > VERSION
git add VERSION
git commit -m "Release ${TAG}"
git tag -a "$TAG" -m "Release ${TAG}"

echo "==> Building CBar-${VERSION}.dmg"
CLAUDEBAR_VERSION="$VERSION" ./Scripts/make_dmg.sh

echo ""
echo "==> Done."
echo "    Tag ${TAG} created locally — push it with:  git push origin main --tags"
echo "    DMG ready at: build/CBar-${VERSION}.dmg"
echo "    Share it directly (Slack/Drive/AirDrop), or run:"
echo "      gh release create ${TAG} build/CBar-${VERSION}.dmg --title \"CBar ${VERSION}\" --generate-notes"
