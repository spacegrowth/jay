#!/bin/bash
# Build Jay-Installer.pkg — a double-click installer that places Jay.app in /Applications
# and launches it (so it prompts for Accessibility + registers its login item).
#
# Usage:  installer/build-installer.sh [version]
# Output: Jay-Installer.pkg in the repo root.
#
# Signing/notarization (later, once you have a Developer ID): set INSTALLER_IDENTITY to a
# "Developer ID Installer: …" name and it will be passed to productbuild --sign; then run
# `xcrun notarytool submit`. Unsigned is fine for testing (right-click → Open the .pkg once).
set -euo pipefail

VERSION="${1:-0.1.2}"
IDENTIFIER="com.jaymac.jay"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"     # repo root
cd "$ROOT"

# 1) Build the app if it isn't there.
[ -d "app/Jay.app" ] || ( cd app && ./build.sh )

# 2) Stage the app under an install root: /Applications/Jay.app
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/root/Applications"
cp -R "app/Jay.app" "$STAGE/root/Applications/"

# 3) Component package (payload + postinstall).
chmod +x installer/scripts/postinstall
pkgbuild \
  --root "$STAGE/root" \
  --install-location "/" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --scripts "installer/scripts" \
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
