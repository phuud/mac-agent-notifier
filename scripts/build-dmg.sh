#!/bin/bash
# Packages the built Agent Notifier.app into a distributable DMG.
# Usage: ./scripts/build-dmg.sh [VERSION]
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -n "${1:-}" ]; then
    VERSION="$1"
else
    VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
    VERSION="${VERSION:-dev}"
fi

DMG_NAME="Agent-Notifier-${VERSION}.dmg"
DIST_DIR="dist"
STAGE_DIR=$(mktemp -d -t agent-notifier-dmg)
trap 'rm -rf "$STAGE_DIR"' EXIT

AGENT_NOTIFIER_INSTALL_DIR="$STAGE_DIR" ./build.sh
ln -s /Applications "$STAGE_DIR/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$DMG_NAME"
hdiutil create \
    -volname "Agent Notifier" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$DIST_DIR/$DMG_NAME" >/dev/null

SHA=$(shasum -a 256 "$DIST_DIR/$DMG_NAME" | awk '{print $1}')
echo "$SHA" > "$DIST_DIR/SHA256"

cat <<OUT

built:   $DIST_DIR/$DMG_NAME
version: $VERSION
sha256:  $SHA

OUT
