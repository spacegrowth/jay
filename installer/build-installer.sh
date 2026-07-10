#!/bin/bash
# Build Jay-Installer.pkg — a double-click installer that places Jay.app in /Applications
# and launches it (so it prompts for Accessibility + registers its login item).
#
# Usage:  installer/build-installer.sh [version]
# Output: Jay-Installer.pkg in the repo root.
#
# Local dev (unsigned / ad-hoc):      installer/build-installer.sh
# Signed + ready for notarization:    APP_IDENTITY="Developer ID Application: …" \
#                                     INSTALLER_IDENTITY="Developer ID Installer: …" \
#                                     installer/build-installer.sh
# Then notarize + staple:
#   xcrun notarytool submit --apple-id "…" --team-id "…" --wait Jay-Installer.pkg
#   xcrun stapler staple Jay-Installer.pkg
set -euo pipefail

VERSION="${1:-0.1.2}"
IDENTIFIER="com.jaymac.jay"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"     # repo root
cd "$ROOT"

# 1) Build the app. If the caller set APP_IDENTITY (Developer ID), pass it through so
#    build.sh signs with hardened runtime + entitlements for notarization.
if [ -n "${APP_IDENTITY:-}" ]; then
  ( export JAY_IDENTITY="$APP_IDENTITY"; cd app && ./build.sh )
else
  [ -d "app/Jay.app" ] || ( cd app && ./build.sh )
fi

# 2) Stage the app under an install root: /Applications/Jay.app
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/root/Applications"
cp -R "app/Jay.app" "$STAGE/root/Applications/"

# 3) Component package (payload + postinstall). Sign it if we have an installer identity.
COMPONENT_SIGN=()
if [ -n "${INSTALLER_IDENTITY:-}" ]; then COMPONENT_SIGN=(--sign "$INSTALLER_IDENTITY"); fi
chmod +x installer/scripts/postinstall
pkgbuild \
  --root "$STAGE/root" \
  --install-location "/" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --scripts "installer/scripts" \
  ${COMPONENT_SIGN[@]+"${COMPONENT_SIGN[@]}"} \
  "$STAGE/Jay-component.pkg"

# 4) Product archive with the installer UI (welcome/conclusion).
SIGN_ARGS=()
if [ -n "${INSTALLER_IDENTITY:-}" ]; then SIGN_ARGS=(--sign "$INSTALLER_IDENTITY"); fi
productbuild \
  --distribution "installer/distribution.xml" \
  --resources "installer/resources" \
  --package-path "$STAGE" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  "Jay-Installer.pkg"

echo "built: $ROOT/Jay-Installer.pkg ($(du -h Jay-Installer.pkg | cut -f1))"

# 5) Notarization hint (only when signed for distribution).
if [ -n "${INSTALLER_IDENTITY:-}" ]; then
  echo ""
  echo "Next, submit for notarization:"
  echo "  xcrun notarytool submit --apple-id \"you@example.com\" --team-id \"YOURTEAM\" --wait Jay-Installer.pkg"
  echo "  xcrun stapler staple Jay-Installer.pkg"
fi
