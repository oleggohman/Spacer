#!/usr/bin/env bash
# Cuts a release in two phases, with a manual test in between.
#
#   scripts/release.sh prepare [major|minor|patch|X.Y.Z]
#       Checks the tree is clean and on the release branch, runs tests, lint, a strict
#       release build and the script tests (test-pppc-profile.sh, test-release.sh), sets the version, and builds build/Spacer.app. Then stop and test the app.
#   scripts/release.sh publish
#       Only after the app was tested: checks build/Spacer.app is still the app prepare built
#       (same CDHash, same signing mode), writes the PPPC profile build/Spacer-PPPC.mobileconfig
#       from it (scripts/make-pppc-profile.sh; skipped with ALLOW_ADHOC=1), packages it into a
#       DMG (no rebuild; signed, and notarized and stapled with NOTARIZE=1), writes the Sparkle
#       appcast build/appcast.xml for it (scripts/make-appcast.sh), then commits the
#       version, tags vX.Y.Z and, when an "origin" remote exists, pushes and publishes a GitHub
#       release with the DMG, the profile and the appcast attached. All three are made before
#       the commit and tag.
#
# RELEASE_BRANCH (default: main) is the branch releases are cut from.
#
# Both phases need SIGN_IDENTITY (a Developer ID Application identity): prepare signs the app,
# publish signs the DMG. Set ALLOW_ADHOC=1 (in both phases) to cut a local release with an
# ad-hoc signed app instead.
#
# Notarization is off by default: the DMG is signed but not notarized, so Gatekeeper on other
# Macs blocks it after download. Set NOTARIZE=1 (in both phases) to notarize and staple the
# DMG; that also needs NOTARY_PROFILE (a notarytool keychain profile). prepare records the
# choice in build/release-state, and publish refuses to run with a different NOTARIZE setting.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STATE="$ROOT/build/release-state"
BRANCH="${RELEASE_BRANCH:-main}"
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

is_adhoc() {
  [[ "${ALLOW_ADHOC:-}" == "1" ]]
}

signing_mode() {
  if is_adhoc; then echo adhoc; else echo developer-id; fi
}

notarization_mode() {
  if notarize_requested; then echo notarized; else echo not-notarized; fi
}

require_signing() {
  if is_adhoc; then
    notarize_requested && fail "NOTARIZE=1 needs a Developer ID signed app, so it cannot be used with ALLOW_ADHOC=1"
    echo "warning: ALLOW_ADHOC=1, so this release is ad-hoc signed and not notarized" >&2
    unset SIGN_IDENTITY NOTARY_PROFILE
    return
  fi
  [[ -n "${SIGN_IDENTITY:-}" ]] ||
    fail "SIGN_IDENTITY is not set (a Developer ID Application identity); set ALLOW_ADHOC=1 for a local ad-hoc release"
  if notarize_requested; then
    [[ -n "${NOTARY_PROFILE:-}" ]] ||
      fail "NOTARIZE=1 needs NOTARY_PROFILE (a notarytool keychain profile)"
  fi
  # The matching line must be a Developer ID Application certificate: an "Apple Development"
  # identity signs the app but cannot be notarized.
  security find-identity -v -p codesigning | grep -F -- "$SIGN_IDENTITY" |
    grep -F '"Developer ID Application: ' >/dev/null ||
    fail "no valid Developer ID Application identity matching \"$SIGN_IDENTITY\" in the keychain"
}

# The app's signature must match the release mode: Developer ID unless ALLOW_ADHOC=1.
check_app_signature() {
  is_adhoc && return
  is_developer_id_signed build/Spacer.app ||
    fail "build/Spacer.app is not signed with a Developer ID Application certificate; prepare again with SIGN_IDENTITY set"
}

# The CDHash identifies the exact signed build, so publish can check it ships the tested app.
app_cdhash() {
  codesign -dvvv build/Spacer.app 2>&1 | sed -n 's/^CDHash=//p'
}

# Sparkle signs the DMG with an EdDSA key in the login keychain. Check the signing tool and the
# key exist before the slow steps, so a missing key or a denied Keychain prompt fails early.
# Ad-hoc releases have no appcast, so they need neither.
require_sparkle_key() {
  is_adhoc && return
  local bin="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
  local sign_update="${SPARKLE_SIGN_UPDATE:-$bin/sign_update}"
  local generate_keys="${SPARKLE_GENERATE_KEYS:-$bin/generate_keys}"
  local account="${SPARKLE_KEY_ACCOUNT:-$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)}"
  [[ -x "$sign_update" ]] || fail "$sign_update not found; run swift package resolve first"
  [[ -x "$generate_keys" ]] || fail "$generate_keys not found; run swift package resolve first"
  "$generate_keys" --account "$account" -p >/dev/null 2>&1 ||
    fail "no Sparkle EdDSA key for account $account in the keychain (or access was denied); see generate_keys"
}

prepare() {
  local bump="${1:-patch}"
  require_signing
  [[ "$(git branch --show-current)" == "$BRANCH" ]] ||
    fail "releases are cut from $BRANCH (set RELEASE_BRANCH to override)"
  [[ -z "$(git status --porcelain)" ]] || fail "the working tree has changes; commit or stash them"

  swift test
  swift format lint --recursive --strict Sources Tests
  swift build -c release -Xswiftc -warnings-as-errors
  require_sparkle_key
  scripts/test-pppc-profile.sh >/dev/null || fail "scripts/test-pppc-profile.sh failed; run it to see which check"
  scripts/test-release.sh >/dev/null || fail "scripts/test-release.sh failed; run it to see which check"

  scripts/version.sh "$bump" >/dev/null
  local version
  version="$(scripts/version.sh --short)"
  if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    git checkout -- Resources/Info.plist
    fail "tag v$version already exists"
  fi

  scripts/bundle.sh
  plutil -lint build/Spacer.app/Contents/Info.plist >/dev/null
  check_app_signature
  local cdhash
  cdhash="$(app_cdhash)"
  [[ -n "$cdhash" ]] || fail "cannot read the CDHash of build/Spacer.app"
  printf 'VERSION=%s\nCOMMIT=%s\nCDHASH=%s\nMODE=%s\nNOTARIZATION=%s\n' \
    "$version" "$(git rev-parse HEAD)" "$cdhash" "$(signing_mode)" "$(notarization_mode)" >"$STATE"

  echo
  echo "Prepared Spacer $(scripts/version.sh) ($(notarization_mode) DMG). Test build/Spacer.app now:"
  echo "  open build/Spacer.app"
  echo "When it passes, run: scripts/release.sh publish"
  echo "To abandon: git checkout -- Resources/Info.plist && rm build/release-state"
}

publish() {
  [[ -f "$STATE" ]] || fail "nothing prepared; run scripts/release.sh prepare first"
  require_signing
  require_sparkle_key
  local VERSION="" COMMIT="" CDHASH="" MODE="" NOTARIZATION=""
  # shellcheck source=/dev/null
  source "$STATE"
  [[ "$MODE" == "$(signing_mode)" ]] ||
    fail "prepare ran in ${MODE:-an unknown} mode but publish runs in $(signing_mode) mode; use the same ALLOW_ADHOC setting or prepare again"
  [[ "$NOTARIZATION" == "$(notarization_mode)" ]] ||
    fail "prepare ran ${NOTARIZATION:-with an unknown notarization setting} but publish runs $(notarization_mode); use the same NOTARIZE setting or prepare again"
  [[ -n "$CDHASH" && "$(app_cdhash)" == "$CDHASH" ]] ||
    fail "build/Spacer.app is not the app prepare built (its CDHash changed); prepare again and test that build"
  [[ "$(git rev-parse HEAD)" == "$COMMIT" ]] ||
    fail "HEAD moved since prepare; prepare again so the tested build matches the tag"
  [[ "$(scripts/version.sh --short)" == "$VERSION" ]] || fail "Info.plist no longer says $VERSION"
  local changed
  changed="$(git status --porcelain | grep -v ' Resources/Info.plist$' || true)"
  [[ -z "$changed" ]] || fail "files other than Resources/Info.plist changed since prepare"

  # The PPPC profile for managed Macs and the DMG (signing, notarization, stapling) are made
  # from the tested app before anything is committed or tagged, so a failure in either leaves
  # no release commit or tag and publish can run again. An ad-hoc app has no stable code
  # requirement, so ad-hoc releases ship without the profile.
  local profile="build/Spacer-PPPC.mobileconfig"
  local assets=("build/Spacer-$VERSION.dmg" "build/Spacer-$VERSION.dmg.sha256")
  # Remove a profile from an earlier run, so an ad-hoc release cannot ship a stale one.
  rm -f "$profile"
  if is_adhoc; then
    echo "ALLOW_ADHOC=1: skipping the PPPC profile (it needs a Developer ID signed app)"
  else
    scripts/make-pppc-profile.sh build/Spacer.app "$profile"
    assets+=("$profile")
  fi
  scripts/make-dmg.sh --skip-build

  # make-dmg.sh can wait minutes on notarization. Check again that nothing moved HEAD or
  # staged other files in that window, so the release commit holds only the version bump
  # and the tag lands on the commit the tested app was built from.
  [[ "$(git rev-parse HEAD)" == "$COMMIT" ]] ||
    fail "HEAD moved while the DMG was made; prepare again so the tested build matches the tag"
  local staged
  staged="$(git diff --cached --name-only | grep -vx 'Resources/Info.plist' || true)"
  [[ -z "$staged" ]] || fail "files other than Resources/Info.plist were staged while the DMG was made: $staged"

  local previous
  previous="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  local notes="$ROOT/build/release-notes-v$VERSION.md"
  {
    echo "## Spacer $VERSION"
    echo
    git log --no-merges --pretty='- %s' ${previous:+"$previous"..HEAD}
  } >"$notes"

  # The Sparkle appcast signs the final DMG, so it comes after stapling. Ad-hoc apps cannot
  # update each other (Sparkle checks the new app's code signature), so they get none.
  local appcast="build/appcast.xml"
  rm -f "$appcast"
  if is_adhoc; then
    echo "ALLOW_ADHOC=1: skipping the Sparkle appcast (updates need a Developer ID signed app)"
  else
    scripts/make-appcast.sh "build/Spacer-$VERSION.dmg" "$notes" "$appcast" build/Spacer.app
    assets+=("$appcast")
  fi

  git add Resources/Info.plist
  git commit -m "chore: release v$VERSION" -- Resources/Info.plist
  git tag -a "v$VERSION" -F "$notes"
  rm -f "$STATE"

  if git remote get-url origin >/dev/null 2>&1; then
    git push origin "$BRANCH" "v$VERSION"
    # An ad-hoc release has no appcast, so it must not become "latest": installed copies fetch
    # releases/latest/download/appcast.xml.
    local latest=()
    is_adhoc && latest=(--latest=false)
    gh release create "v$VERSION" "${assets[@]}" --title "Spacer $VERSION" --notes-file "$notes" ${latest[@]+"${latest[@]}"}
  else
    echo "No origin remote: the tag and release files stay local."
  fi
  echo "Released Spacer $VERSION: tag v$VERSION, ${assets[*]}"
}

case "${1:-}" in
  prepare) prepare "${2:-}" ;;
  publish) publish ;;
  *)
    echo "usage: $0 prepare [major|minor|patch|X.Y.Z] | publish" >&2
    exit 64
    ;;
esac
