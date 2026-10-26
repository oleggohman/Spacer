#!/usr/bin/env bash
# Builds the release binary and wraps it into build/Spacer.app.
#
# SIGN_IDENTITY  Developer ID Application identity to sign with (the certificate's name or
#                SHA-1 hash, as listed by `security find-identity -v -p codesigning`). The app
#                is then signed with the hardened runtime and a secure timestamp, which
#                notarization and the MDM PPPC profile need. When unset, the app is
#                ad-hoc signed, which is fine for local builds only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Spacer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Spacer" "$APP/Contents/MacOS/Spacer"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sparkle (auto-update). The binary finds it through its @executable_path/../Frameworks rpath.
# ditto keeps the framework's Versions symlinks.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$FRAMEWORK"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Sign inside-out: Sparkle's helpers, then the framework, then the app. Downloader.xpc keeps
  # its own entitlements (network access for sandboxed hosts).
  sign() { codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$@"; }
  SPARKLE="$FRAMEWORK/Versions/B"
  sign "$SPARKLE/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Autoupdate"
  sign "$SPARKLE/Updater.app"
  sign "$FRAMEWORK"
  sign "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "Signed with: $SIGN_IDENTITY"
  echo "Designated requirement: $(codesign -dr - "$APP" 2>&1 | designated_requirement)"
else
  codesign --force --deep -s - "$APP"
  echo "Ad-hoc signed (set SIGN_IDENTITY to sign with a Developer ID)"
fi

echo "Built $APP"
