#!/bin/bash
# Build Jay.dmg — a drag-and-drop disk image: Jay.app beside an "Applications" alias, so the user
# just drags Jay onto Applications (no admin password, no installer script). Assumes app/Jay.app is
# already built, Developer ID-signed, and notarized+stapled. Signs the .dmg with APP_IDENTITY when
# set (Developer ID Application) so Gatekeeper trusts the container itself.
#
# Usage:  APP_IDENTITY="Developer ID Application: …" installer/build-dmg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
APP="$ROOT/app/Jay.app"
DMG="$ROOT/Jay.dmg"
APP_IDENTITY="${APP_IDENTITY:-}"

[ -d "$APP" ] || { echo "no app at $APP — build it first" >&2; exit 1; }

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Jay.app"
ln -s /Applications "$STAGE/Applications"          # the drag target shown in the window

rm -f "$DMG"
hdiutil create -volname "Jay" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [ -n "$APP_IDENTITY" ]; then                    # sign the container so Gatekeeper trusts it directly
  codesign --force --sign "$APP_IDENTITY" --timestamp "$DMG"
fi
echo "built: $DMG ($(du -h "$DMG" | cut -f1))"
