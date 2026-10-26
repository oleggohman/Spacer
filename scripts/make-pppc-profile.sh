#!/usr/bin/env bash
# Writes the MDM PPPC profile for Spacer: fills the code requirement of
# Resources/Profiles/Spacer-PPPC.mobileconfig.template with the designated requirement of
# the signed app.
#
# Usage: scripts/make-pppc-profile.sh [APP] [OUT]
#   APP  the signed app (default: build/Spacer.app, built by SIGN_IDENTITY=... scripts/bundle.sh)
#   OUT  the profile to write (default: build/Spacer-PPPC.mobileconfig)
#
# The app must have a valid Developer ID Application signature. Anything else is refused: an
# ad-hoc build's requirement is a cdhash that changes on every build, and an Apple Development
# or self-signed requirement names a certificate that is not meant for distribution.
# The app's bundle ID must match every Identifier in the template.
#
# scripts/test-pppc-profile.sh checks this script with a stub codesign.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/Resources/Profiles/Spacer-PPPC.mobileconfig.template"
APP="${1:-$ROOT/build/Spacer.app}"
OUT="${2:-$ROOT/build/Spacer-PPPC.mobileconfig}"
PLACEHOLDER="__CODE_REQUIREMENT__"
# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -f "$TEMPLATE" ]] || fail "template not found: $TEMPLATE"
[[ -d "$APP" ]] || fail "app not found: $APP (build it with SIGN_IDENTITY=... scripts/bundle.sh)"

# The bundle ID the template grants access to.
expected_id="$(plutil -extract PayloadContent.0.Services.SystemPolicyAllFiles.0.Identifier raw "$TEMPLATE" 2>/dev/null)" ||
  fail "no SystemPolicyAllFiles Identifier in $TEMPLATE"
app_id="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist" 2>/dev/null)" ||
  fail "no CFBundleIdentifier in $APP/Contents/Info.plist"
[[ "$app_id" == "$expected_id" ]] || fail "$APP is $app_id, but the profile is for $expected_id"

if ! verify_info="$(codesign --verify --strict "$APP" 2>&1)"; then
  fail "the code signature of $APP is not valid: $verify_info"
fi
if ! sign_info="$(codesign -dr - "$APP" 2>&1)"; then
  fail "cannot read the code signature of $APP: $sign_info"
fi
requirement="$(printf '%s\n' "$sign_info" | designated_requirement)"
[[ -n "$requirement" ]] || fail "no designated requirement in the signature of $APP"
if [[ "$requirement" == cdhash* ]]; then
  fail "$APP is ad-hoc signed (requirement: $requirement). Sign it with a Developer ID: SIGN_IDENTITY=... scripts/bundle.sh"
fi
is_developer_id_requirement "$requirement" ||
  fail "$APP is not signed with a Developer ID Application certificate (requirement: $requirement)"
[[ "$requirement" == *"identifier \"$expected_id\""* ]] ||
  fail "the requirement of $APP does not name $expected_id (requirement: $requirement)"

services="$(sed -n 's/^[[:space:]]*<key>\(SystemPolicy[A-Za-z]*\)<\/key>.*/\1/p' "$TEMPLATE")"
[[ -n "$services" ]] || fail "no services found in $TEMPLATE"

# plutil sets each entry's requirement and does the XML escaping; requirements contain
# quotes and may contain & or <.
mkdir -p "$(dirname "$OUT")"
tmp="$(mktemp "${TMPDIR:-/tmp}/spacer-pppc.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cp "$TEMPLATE" "$tmp"
for service in $services; do
  entry="PayloadContent.0.Services.$service.0"
  [[ "$(plutil -extract "$entry.Identifier" raw "$tmp")" == "$expected_id" ]] ||
    fail "$service is not for $expected_id in $TEMPLATE"
  [[ "$(plutil -extract "$entry.CodeRequirement" raw "$tmp")" == "$PLACEHOLDER" ]] ||
    fail "$service has no $PLACEHOLDER in $TEMPLATE"
  plutil -replace "$entry.CodeRequirement" -string "$requirement" "$tmp"
done

plutil -lint -s "$tmp" || fail "the filled profile is not a valid plist"
if grep -q "$PLACEHOLDER" "$tmp"; then
  fail "the filled profile still contains $PLACEHOLDER"
fi
chmod 644 "$tmp"
mv "$tmp" "$OUT"
trap - EXIT

echo "Code requirement: $requirement"
echo "Services: ${services//$'\n'/ }"
echo "Wrote $OUT"
