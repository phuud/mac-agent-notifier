#!/bin/bash
# Build "Agent Notifier.app" and install to $INSTALL_DIR/"Agent Notifier.app".
# Defaults to ~/Applications. Override with AGENT_NOTIFIER_INSTALL_DIR.
set -euo pipefail

cd "$(dirname "$0")"

INSTALL_DIR="${AGENT_NOTIFIER_INSTALL_DIR:-$HOME/Applications}"
DEST="$INSTALL_DIR/Agent Notifier.app"

mkdir -p "$INSTALL_DIR"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp Info.plist "$DEST/Contents/Info.plist"
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$DEST/Contents/Resources/AppIcon.icns"
fi
cp notify.sh "$DEST/Contents/Resources/notify.sh"
chmod +x "$DEST/Contents/Resources/notify.sh"

swiftc \
    -O \
    -target arm64-apple-macos11 \
    -framework AppKit \
    -framework UserNotifications \
    -o "$DEST/Contents/MacOS/AgentNotifier" \
    main.swift

codesign --force --sign - "$DEST"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$DEST"

echo "built: $DEST"
