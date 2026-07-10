#!/bin/bash
# Build Jay as a signed .app bundle, so macOS remembers its
# Accessibility + Automation permissions across rebuilds (stable identity).
set -e
cd "$(dirname "$0")"

APP="Jay.app"
IDENTITY="${JAY_IDENTITY:--}"   # ad-hoc by default; `export JAY_IDENTITY=<signing identity>` for a stable
                                # local build whose Accessibility/Automation grants survive rebuilds

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns menubar-glyph.png "$APP/Contents/Resources/"   # Finder/About icon + menu-bar template glyph

# Bundle the built-in plugins inside the app (Resources/Plugins). They travel with the app and are
# OFF by default — the user enables the ones they want (first-run checklist / Preferences ▸ Plugins).
mkdir -p "$APP/Contents/Resources/Plugins"
	# Auto-discover: bundle every plugin under ../plugins/ — no hardcoded list.
	# Works identically in repos with different plugin sets; nothing to configure per checkout.
	if [ -d "../plugins" ]; then
	  for p in ../plugins/*/; do
	    [ -d "$p" ] && cp -R "$p" "$APP/Contents/Resources/Plugins/$(basename "$p")"
	  done
	fi

# Embed the vendored Sparkle framework (app/Vendor/Sparkle.framework) into the bundle. It travels
# in Contents/Frameworks and is found at runtime via the @executable_path/../Frameworks rpath added
# to the swiftc link below. Nested Sparkle code is code-signed further down, before the app itself.
mkdir -p "$APP/Contents/Frameworks"
ditto Vendor/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"

# Source is grouped by concern: Core/ Contexts/ Adapters/ Triggers/ UI/. Tests/ is the standalone
# logic-test target (not part of the app). One swiftc invocation compiles them all together.
# -F Vendor / -framework Sparkle links against the vendored framework; the -rpath makes the loader
# resolve @rpath/Sparkle.framework to the copy embedded in Contents/Frameworks.
SRC=$(find Core Contexts Adapters Triggers UI -name '*.swift' | sort)
swiftc -swift-version 5 $SRC -o "$APP/Contents/MacOS/Jay" \
    -F Vendor -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks

# Sign inside-out, deepest-first: every nested Sparkle bundle/helper must carry a hardened-runtime
# signature with OUR identity BEFORE the app is sealed, or --deep --strict verification fails.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for nested in \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE"
do
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$nested"
done

codesign --force --sign "$IDENTITY" \
    --options runtime \
    --entitlements Jay.entitlements \
    --timestamp \
    "$APP"

echo "built + signed: $(pwd)/$APP"
echo "run:  open $APP    (then double-tap ⌥)"
