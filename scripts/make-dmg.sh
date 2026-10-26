#!/usr/bin/env bash
# Packages build/Spacer.app into build/Spacer-<version>.dmg, with an Applications shortcut,
# and writes its SHA-256 next to it.
#
#   scripts/make-dmg.sh               build the app first (scripts/bundle.sh)
#   scripts/make-dmg.sh --skip-build  package the app already in build/ (the tested one)
#
# SIGN_IDENTITY   Developer ID Application identity. When set, the DMG is signed with it
#                 (and scripts/bundle.sh signs the app with it).
# NOTARIZE=1      Notarizes the signed DMG and staples the ticket to it. Needs SIGN_IDENTITY,
#                 NOTARY_PROFILE and a Developer ID signed app. Unset or 0 (the default) skips
#                 notarization, and the DMG is not notarized.
# NOTARY_PROFILE  notarytool keychain profile (created with `xcrun notarytool store-credentials`).
#                 Used only with NOTARIZE=1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

fail() {
  echo "error: $*" >&2
  exit 1
}

case "${NOTARIZE:-}" in
  ''|0|1) ;;
  *) fail "NOTARIZE must be 1 (notarize) or unset or 0 (do not notarize), not \"$NOTARIZE\"" ;;
esac
if notarize_requested; then
  [[ -n "${NOTARY_PROFILE:-}" ]] || fail "NOTARIZE=1 needs NOTARY_PROFILE (a notarytool keychain profile)"
  [[ -n "${SIGN_IDENTITY:-}" ]] || fail "NOTARIZE=1 needs SIGN_IDENTITY; notarization needs a Developer ID signature"
fi

if [[ "${1:-}" != "--skip-build" ]]; then
  scripts/bundle.sh
fi

APP="$ROOT/build/Spacer.app"
[[ -d "$APP" ]] || fail "$APP not found; run scripts/bundle.sh first"

VERSION="$(scripts/version.sh --short)"
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" ]] || fail "the app is $APP_VERSION but Info.plist says $VERSION; rebuild it"
codesign --verify --deep --strict "$APP"
# A Developer ID signed DMG must wrap a Developer ID signed app: an ad-hoc or Apple Development
# signed app cannot be notarized.
if [[ -n "${SIGN_IDENTITY:-}" ]] && ! is_developer_id_signed "$APP"; then
  fail "$APP is not signed with a Developer ID Application certificate; rebuild it with SIGN_IDENTITY set before signing the DMG"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$ROOT/build/Spacer-$VERSION.dmg"
rm -f "$DMG" "$DMG.sha256"
hdiutil create -quiet -volname "Spacer $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"
  codesign --verify --strict "$DMG"
fi
if notarize_requested; then
  # notarytool's exit code does not always reflect the verdict, so read the status and show
  # Apple's log when it is not Accepted.
  result="$(xcrun notarytool submit "$DMG" --wait --keychain-profile "$NOTARY_PROFILE" --output-format json)" ||
    fail "notarytool submit failed: $result"
  status="$(plutil -extract status raw - <<<"$result" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    id="$(plutil -extract id raw - <<<"$result" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    fail "notarization of $DMG ended with status \"${status:-unknown}\" (submission ${id:-unknown}): $result"
  fi
  echo "Notarized: submission $(plutil -extract id raw - <<<"$result")"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
(cd "$ROOT/build" && shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG").sha256")

echo "Built $DMG"
cat "$DMG.sha256"
if ! notarize_requested; then
  echo "note: $DMG is not notarized (NOTARIZE is not 1). Gatekeeper on other Macs blocks it after download; set NOTARIZE=1 and NOTARY_PROFILE to notarize it."
fi
