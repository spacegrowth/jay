#!/bin/bash
# Build, sign, notarize, and staple Jay-Installer.pkg in one shot.
#
# Produces a distributable installer that passes Gatekeeper with no
# "unidentified developer" warning, verified even offline.
#
# Usage:   installer/notarize.sh [version]
#          installer/notarize.sh 0.1.3
#
# Prerequisites (one-time setup, already done on Vamsi's machine):
#   - Developer ID Application + Developer ID Installer certs in the login keychain
#     (check with: security find-identity -v)
#   - notarytool credentials saved as keychain profile "jay-notary"
#     (set up with: xcrun notarytool store-credentials jay-notary \
#                     --apple-id <your-apple-id> --team-id 87CWAR5GNP)
#
# Personal Apple ID + full runbook/recovery notes are kept OUT of the repo,
# in ~/Documents/Jay-Notarization.md (local only).
set -euo pipefail

TEAM_ID="87CWAR5GNP"
APP_IDENTITY="Developer ID Application: Vamsi Guntuku (${TEAM_ID})"
INSTALLER_IDENTITY="Developer ID Installer: Vamsi Guntuku (${TEAM_ID})"
NOTARY_PROFILE="jay-notary"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-0.1.2}"
PKG="Jay-Installer.pkg"

echo "==> Building + signing (v${VERSION})"
APP_IDENTITY="$APP_IDENTITY" \
INSTALLER_IDENTITY="$INSTALLER_IDENTITY" \
  installer/build-installer.sh "$VERSION"

echo "==> Verifying signatures before submit"
codesign --verify --deep --strict --verbose=2 app/Jay.app
pkgutil --check-signature "$PKG" | head -3

echo "==> Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$PKG"

echo "==> Final Gatekeeper check"
xcrun stapler validate "$PKG"
spctl -a -vvv -t install "$PKG" || true

echo ""
echo "Done. Distributable installer ready: $ROOT/$PKG"
