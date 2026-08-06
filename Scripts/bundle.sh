#!/bin/bash
# Assembles ClaudeIsland.app from SwiftPM build products.
#
# No Xcode required: SwiftPM produces the binaries, this lays out the bundle and
# ad-hoc signs it. A real .app is not cosmetic — an unbundled binary has limited
# standing with the window server, and LSUIElement only takes effect from an
# Info.plist.

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/ClaudeIsland.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product ClaudeIslandApp
swift build -c "$CONFIG" --product claude-island-notify

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_DIR/ClaudeIslandApp" "$MACOS/ClaudeIsland"
cp "$BIN_DIR/claude-island-notify" "$MACOS/claude-island-notify"

VERSION="0.1.0"
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>ClaudeIsland</string>
    <key>CFBundleDisplayName</key>           <string>ClaudeIsland</string>
    <key>CFBundleIdentifier</key>            <string>com.claudeisland.hud</string>
    <key>CFBundleExecutable</key>            <string>ClaudeIsland</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <!-- No Dock icon, no app switcher entry. The menu bar extra is the only chrome. -->
    <key>LSUIElement</key>                   <true/>
    <key>NSHighResolutionCapable</key>       <true/>
    <!-- Unsandboxed: the UDS lives in ~/.claude-island and transcripts are read
         from ~/.claude/projects, both outside any container. -->
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>NSSupportsSuddenTermination</key>    <false/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
# Ad-hoc is all Command Line Tools can do without a Developer ID. It is enough
# for local use; Gatekeeper will still quarantine a copy downloaded from
# elsewhere.
codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo ""
echo "Built $APP"
echo "  hook client: $MACOS/claude-island-notify"
echo ""
echo "Run:      open $APP"
echo "Install:  cp -R $APP /Applications/"
echo "Hooks:    $MACOS/ClaudeIsland --install-hooks"
