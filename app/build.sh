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

# Hard-to-script apps (some Electron and native targets) are external plugins now — the app ships zero CDP/debug code.
swiftc -swift-version 5 Adapters.swift PluginHost.swift EdgeTrigger.swift UsageLog.swift \
  ContextKey.swift ContextEngine.swift ContextOverrides.swift ContextLabeler.swift ContextLabelerAI.swift ContextStore.swift \
  SwitcherPanel.swift Trigger.swift Settings.swift Onboarding.swift main.swift \
  -o "$APP/Contents/MacOS/Jay"

codesign --force --sign "$IDENTITY" "$APP"

echo "built + signed: $(pwd)/$APP"
echo "run:  open $APP    (then double-tap ⌥)"
