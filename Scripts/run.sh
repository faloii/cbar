#!/usr/bin/env bash
# Build and launch ClaudeBar for quick iteration.
set -euo pipefail
cd "$(dirname "$0")/.."

# Kill any previous instance so the menu-bar icon doesn't pile up.
pkill -x CBar 2>/dev/null || true

swift build -c debug
exec .build/debug/CBar "$@"
