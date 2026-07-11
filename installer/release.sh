#!/bin/bash
# Full Jay release: build → sign → notarize → staple BOTH artifacts, EdDSA-sign the
# Sparkle appcast, and publish to GitHub Pages (feed) + a GitHub Release (downloads).
#
# Produces per release:
#   Jay.dmg                — first-time install: drag-and-drop disk image (notarized + stapled)
#   Jay-<ver>.app.zip      — Sparkle auto-update payload (notarized + stapled .app)
#   site/appcast.xml       — the EdDSA-signed Sparkle feed (deploys to Pages on push)
#
# Usage:   installer/release.sh <version>        e.g. installer/release.sh 0.2.8
#
# Prerequisites (see ~/Documents/Jay-Notarization.md):
#   - Developer ID Application + Installer certs in the login keychain
#   - notarytool profile "jay-notary"
#   - Sparkle EdDSA private key in the login keychain (generate_appcast finds it automatically)
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: installer/release.sh <version>   (e.g. 0.2.8)" >&2; exit 1; }
VERSION="$1"
TEAM_ID="87CWAR5GNP"
APP_IDENTITY="Developer ID Application: Vamsi Guntuku (${TEAM_ID})"
INSTALLER_IDENTITY="Developer ID Installer: Vamsi Guntuku (${TEAM_ID})"
NOTARY_PROFILE="jay-notary"
SPARKLE_VER="2.9.4"
TAG="v${VERSION}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/app/Jay.app"
DIST="$ROOT/build/release"           # gitignored work dir
TOOLS="$ROOT/installer/.sparkle-tools" # gitignored cached Sparkle CLI tools
ZIP="$DIST/Jay-${VERSION}.app.zip"

rm -rf "$DIST"; mkdir -p "$DIST"

# 0) Fetch Sparkle CLI tools (generate_appcast/sign_update) once, cached + gitignored.
if [ ! -x "$TOOLS/bin/generate_appcast" ]; then
  echo "==> Fetching Sparkle ${SPARKLE_VER} CLI tools"
  mkdir -p "$TOOLS"
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VER}/Sparkle-${SPARKLE_VER}.tar.xz" \
    | tar -xJ -C "$TOOLS"
fi

# 1) Stamp the version into Info.plist (Sparkle compares CFBundleVersion to decide "newer").
echo "==> Stamping version ${VERSION} into Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" app/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" app/Info.plist

# 2) Build + sign the .app with Developer ID (build.sh embeds + signs Sparkle).
echo "==> Building + signing Jay.app"
( export JAY_IDENTITY="$APP_IDENTITY"; cd app && ./build.sh )

# 3) Zip the app and notarize the ZIP (notarizes the .app's cdhash), then staple the .app.
echo "==> Notarizing the .app (via zip)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
# Re-zip the now-stapled app — this is the payload Sparkle downloads.
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
xcrun stapler validate "$APP"

# 4) Build the drag-and-drop DMG from the SAME stapled app, then notarize + staple the .dmg.
echo "==> Building + notarizing Jay.dmg"
APP_IDENTITY="$APP_IDENTITY" installer/build-dmg.sh
xcrun notarytool submit "$ROOT/Jay.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$ROOT/Jay.dmg"

# 5) Generate the EdDSA-signed appcast. generate_appcast finds the private key in the keychain and
#    signs each archive in $DIST; --download-url-prefix makes enclosures point at the Release assets.
echo "==> Generating EdDSA-signed appcast.xml"
"$TOOLS/bin/generate_appcast" \
  --download-url-prefix "https://github.com/spacegrowth/jay/releases/download/${TAG}/" \
  "$DIST"
cp "$DIST/appcast.xml" "$ROOT/site/appcast.xml"

# 6) Publish the downloads as a GitHub Release FIRST — so the release + assets exist before the
#    push below deploys the site, and before the Pages workflow fetches Jay.dmg into the site.
echo "==> Creating GitHub Release ${TAG}"
gh release create "$TAG" \
  "$ROOT/Jay.dmg" \
  "$ZIP" \
  --title "${TAG}" \
  --notes "Jay ${VERSION}. Download \`Jay.dmg\` and drag Jay to Applications (notarized). Existing installs auto-update via Sparkle."

# 7) Publish the feed (commit appcast.xml + version bump; push deploys Pages). The Pages workflow
#    fetches the just-published Jay.dmg into the site so the website serves it SAME-ORIGIN — which
#    makes the download attribute stick and the file save as "Jay.dmg" (not the page title).
echo "==> Publishing appcast to GitHub Pages (site/appcast.xml)"
git add site/appcast.xml app/Info.plist
git commit -m "Release ${TAG}: appcast + version bump" || echo "(nothing to commit)"
git push origin main

echo ""
echo "Done. Released ${TAG}:"
echo "  dmg:     $ROOT/Jay.dmg"
echo "  update:  $ZIP"
echo "  appcast: https://spacegrowth.github.io/jay/appcast.xml (deploying via Pages)"
