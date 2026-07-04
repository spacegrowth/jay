#!/bin/bash
# Build Jay as a signed .app bundle, so macOS remembers its
# Accessibility + Automation permissions across rebuilds (stable identity).
set -e
cd "$(dirname "$0")"

APP="Jay.app"
IDENTITY="-"   # ad-hoc sign; set your own Developer ID for a notarized release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns menubar-glyph.png "$APP/Contents/Resources/"   # Finder/About icon + menu-bar template glyph

# Source is grouped by concern: Core/ Contexts/ Adapters/ Triggers/ UI/. Tests/ is the standalone
# logic-test target (not part of the app). One swiftc invocation compiles them all together.
SRC=$(find Core Contexts Adapters Triggers UI -name '*.swift' | sort)
swiftc -swift-version 5 $SRC -o "$APP/Contents/MacOS/Jay"

codesign --force --sign "$IDENTITY" "$APP"

echo "built + signed: $(pwd)/$APP"
echo "run:  open $APP    (then double-tap ⌥)"
