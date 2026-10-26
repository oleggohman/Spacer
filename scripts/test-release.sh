#!/usr/bin/env bash
# Checks `scripts/release.sh publish` without certificates, notarization or GitHub: each case
# runs in a throwaway copy of the repo with stub codesign, security and gh on PATH, a stub
# scripts/make-dmg.sh and a local bare repo as origin (named https://github.com/<feed repo>.git,
# rewritten to the bare repo with url.insteadOf, so the origin check sees a GitHub URL). The NOTARIZE cases run the real
# make-dmg.sh instead, with stub hdiutil and xcrun (notarytool and stapler are logged, not run).
# Nothing touches this checkout. Exits non-zero when any check fails.
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spacer-release-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=scripts/lib/check.sh
source "$SRC/scripts/lib/check.sh"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

DEVELOPER_ID_IDENTITY="Developer ID Application: Test (ABCDE12345)"
FEED_REPO="$(plutil -extract SUFeedURL raw "$SRC/Resources/Info.plist" | sed -E 's|^https://github.com/([^/]+/[^/]+)/.*|\1|')"
FEED_REMOTE="https://github.com/$FEED_REPO.git"
APP_ID="$(plutil -extract CFBundleIdentifier raw "$SRC/Resources/Info.plist")"
DEVELOPER_ID_REQUIREMENT="designated => identifier \"$APP_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = ABCDE12345"

BIN="$WORK/bin"
mkdir -p "$BIN"
cat >"$BIN/codesign" <<'EOF'
#!/usr/bin/env bash
# Stub: -dvvv prints STUB_CDHASH, -dr prints STUB_REQUIREMENT, --verify and --force pass.
case "$1" in
  --verify|--force) exit 0 ;;
  -dvvv) echo "CDHash=${STUB_CDHASH:-1111}" >&2 ;;
  -dr) printf '%s\n' "$STUB_REQUIREMENT" ;;
  *) exit 2 ;;
esac
EOF
cat >"$BIN/security" <<'EOF'
#!/usr/bin/env bash
printf '  1) 0123456789ABCDEF "%s"\n' "$STUB_IDENTITY"
EOF
# Stub gh: `auth status` passes unless STUB_GH_AUTH=fail; `release view` finds a release only
# with STUB_GH_RELEASE_EXISTS=1; `release create` logs its arguments to STUB_GH_LOG and fails
# with STUB_GH_CREATE=fail.
cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") [[ "${STUB_GH_AUTH:-}" != fail ]] ;;
  "release view") [[ "${STUB_GH_RELEASE_EXISTS:-}" == 1 ]] ;;
  "release create")
    echo "$*" >"$STUB_GH_LOG"
    [[ "${STUB_GH_CREATE:-}" != fail ]]
    ;;
  *) exit 2 ;;
esac
EOF
# Stub curl: serves STUB_FEED (the appcast the release just made) for the feed check, or fails
# like a 404 when it is unset.
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
[[ -n "${STUB_FEED:-}" && -f "$STUB_FEED" ]] || exit 22
cat "$STUB_FEED"
EOF
# Stub mktemp: make-dmg.sh's `mktemp -d` (no template) goes under TMPDIR, the test's own
# directory, because macOS mktemp ignores TMPDIR and /var/folders is not always writable.
cat >"$BIN/mktemp" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" == 1 && "$1" == -d ]]; then /usr/bin/mktemp -d "$TMPDIR/stage.XXXXXX"; else /usr/bin/mktemp "$@"; fi
EOF
# Stub hdiutil: `create` writes the DMG (its last argument); `verify` passes.
cat >"$BIN/hdiutil" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == create ]]; then echo dmg >"${@: -1}"; fi
EOF
# Stub xcrun: logs every call to STUB_XCRUN_LOG; notarytool submit reports an accepted submission.
cat >"$BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_XCRUN_LOG"
if [[ "$1 $2" == "notarytool submit" ]]; then printf '{"id":"stub-1","status":"Accepted"}\n'; fi
EOF
# Stub sign_update (Sparkle): prints the enclosure attributes for the DMG it is given.
# STUB_SIGN=fail exits non-zero; STUB_SIGN=malformed prints output without a signature.
cat >"$BIN/sign_update" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == --account && -f "$3" ]] || exit 2
[[ "${STUB_SIGN:-}" != fail ]] || { echo "stub: no key" >&2; exit 1; }
[[ "${STUB_SIGN:-}" != malformed ]] || { echo "garbage"; exit 0; }
printf 'sparkle:edSignature="c3R1Yg==" length="%s"\n' "$(wc -c <"$3" | tr -d ' ')"
EOF
# Stub generate_keys (Sparkle): `--account A -p` prints a public key, or fails with STUB_NO_KEY=1.
cat >"$BIN/generate_keys" <<'EOF'
#!/usr/bin/env bash
[[ "${STUB_NO_KEY:-}" != 1 ]] || exit 1
echo "c3R1YnB1YmxpY2tleQ=="
EOF
chmod +x "$BIN"/*

# new_repo DIR [noorigin]: a committed copy of the repo with a prepared release (version
# bumped, build/Spacer.app and build/release-state as prepare leaves them).
new_repo() {
  local dir="$1"
  mkdir -p "$dir/repo"
  cp -R "$SRC/scripts" "$SRC/Resources" "$SRC/.gitignore" "$dir/repo/"
  # REAL_DMG=1 keeps the real make-dmg.sh (see the notarization checks at the end).
  if [[ "${REAL_DMG:-}" == 1 ]]; then cp "$SRC/scripts/make-dmg.sh" "$dir/repo/scripts/make-dmg.sh"; fi
  if [[ "${REAL_DMG:-}" != 1 ]]; then cat >"$dir/repo/scripts/make-dmg.sh" <<'EOF'
#!/usr/bin/env bash
# Stub: writes the DMG and its checksum, or fails with STUB_DMG_FAIL=1 (as a rejected
# notarization would).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${STUB_DMG_FAIL:-}" != 1 ]] || { echo "stub: notarization rejected" >&2; exit 1; }
# STUB_DMG_STAGE=1: another process stages a file while the DMG is being made.
if [[ "${STUB_DMG_STAGE:-}" == 1 ]]; then echo x >stray.txt; git add stray.txt; fi
# STUB_DMG_COMMIT=1: another process commits while the DMG is being made.
if [[ "${STUB_DMG_COMMIT:-}" == 1 ]]; then
  echo x >stray.txt
  git add stray.txt
  git -c user.name=t -c user.email=t@t commit -q -m stray
fi
v="$(scripts/version.sh --short)"
echo dmg >"build/Spacer-$v.dmg"
echo sha >"build/Spacer-$v.dmg.sha256"
EOF
  fi
  chmod +x "$dir/repo/scripts/make-dmg.sh"
  (
    cd "$dir/repo" || exit 1
    git init -q -b main
    git add -A
    git commit -q -m init
    if [[ "${2:-}" != noorigin ]]; then
      git init -q --bare "$dir/origin.git"
      git remote add origin "${ORIGIN_URL:-$FEED_REMOTE}"
      git config "url.$dir/origin.git.insteadOf" "${ORIGIN_URL:-$FEED_REMOTE}"
    fi
    scripts/version.sh patch >/dev/null
    mkdir -p build/Spacer.app/Contents
    cp Resources/Info.plist build/Spacer.app/Contents/Info.plist
    printf 'VERSION=%s\nCOMMIT=%s\nCDHASH=1111\nMODE=%s\nNOTARIZATION=%s\n' \
      "$(scripts/version.sh --short)" "$(git rev-parse HEAD)" "${STATE_MODE:-developer-id}" \
      "${STATE_NOTARIZATION:-not-notarized}" >build/release-state
  )
}

# publish DIR [VAR=VALUE...]: runs release.sh publish there; returns its status.
publish() {
  local dir="$1"
  shift
  (
    cd "$dir/repo" || exit 1
    env -u ALLOW_ADHOC -u SIGN_IDENTITY -u NOTARY_PROFILE -u NOTARIZE PATH="$BIN:$PATH" \
      TMPDIR="$dir" \
      STUB_IDENTITY="$DEVELOPER_ID_IDENTITY" STUB_REQUIREMENT="$DEVELOPER_ID_REQUIREMENT" \
      STUB_GH_LOG="$dir/gh-args" STUB_XCRUN_LOG="$dir/xcrun-calls" \
      STUB_FEED="$dir/repo/build/appcast.xml" FEED_RETRY_SECONDS=0 \
      SPARKLE_SIGN_UPDATE="$BIN/sign_update" SPARKLE_GENERATE_KEYS="$BIN/generate_keys" \
      SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY" \
      "$@" scripts/release.sh publish
  ) >"$dir/log" 2>&1
}

version_of() { (cd "$1/repo" && scripts/version.sh --short); }
has_tag() { git -C "$1/repo" rev-parse -q --verify "refs/tags/v$(version_of "$1")" >/dev/null; }
no_tag() { ! has_tag "$1"; }
head_is_init() { [[ "$(git -C "$1/repo" log -1 --pretty=%s)" == init ]]; }
head_is_release() { [[ "$(git -C "$1/repo" log -1 --pretty=%s)" == "chore: release v$(version_of "$1")" ]]; }
no_dmg() { [[ ! -e "$1/repo/build/Spacer-$(version_of "$1").dmg" ]]; }
state_kept() { [[ -f "$1/repo/build/release-state" ]]; }
state_gone() { [[ ! -f "$1/repo/build/release-state" ]]; }
gh_has() { grep -qF -- "$2" "$1/gh-args" 2>/dev/null; }
gh_lacks() { ! gh_has "$@"; }
gh_not_called() { [[ ! -f "$1/gh-args" ]]; }
xcrun_called() { grep -qF -- "$2" "$1/xcrun-calls" 2>/dev/null; }
notary_not_called() { ! xcrun_called "$1" notarytool && ! xcrun_called "$1" stapler; }
origin_has_tag() { git --git-dir="$1/origin.git" rev-parse -q --verify "refs/tags/v$(version_of "$1")" >/dev/null; }

# refused NAME DIR [VAR=VALUE...]: publish must fail and leave no commit, tag or push.
refused() {
  local name="$1" dir="$2"
  shift 2
  publish "$dir" "$@"
  check "$name: exits non-zero" test $? -ne 0
  check "$name: no release commit" head_is_init "$dir"
  check "$name: no tag" no_tag "$dir"
  check "$name: release-state kept" state_kept "$dir"
  check "$name: nothing published" gh_not_called "$dir"
}

d="$WORK/devid"
new_repo "$d"
publish "$d"
check "Developer ID: exits 0" test $? -eq 0
check "Developer ID: release commit" head_is_release "$d"
check "Developer ID: tag" has_tag "$d"
check "Developer ID: tag pushed" origin_has_tag "$d"
check "Developer ID: release-state removed" state_gone "$d"
check "Developer ID: profile written" plutil -lint -s "$d/repo/build/Spacer-PPPC.mobileconfig"
check "Developer ID: gh gets the DMG" gh_has "$d" "build/Spacer-$(version_of "$d").dmg "
check "Developer ID: gh gets the checksum" gh_has "$d" "build/Spacer-$(version_of "$d").dmg.sha256"
check "Developer ID: gh gets the profile" gh_has "$d" "build/Spacer-PPPC.mobileconfig"
check "Developer ID: appcast written" xmllint --noout "$d/repo/build/appcast.xml"
check "Developer ID: appcast points at the release DMG" grep -qF \
  "releases/download/v$(version_of "$d")/Spacer-$(version_of "$d").dmg" "$d/repo/build/appcast.xml"
check "Developer ID: appcast carries the EdDSA signature" grep -qF \
  'sparkle:edSignature="c3R1Yg=="' "$d/repo/build/appcast.xml"
check "Developer ID: gh gets the appcast" gh_has "$d" "build/appcast.xml"
check "Developer ID: gh release is the latest" gh_lacks "$d" "--latest=false"
check "Developer ID: gh release targets the feed repo" gh_has "$d" "--repo $FEED_REPO"
check "Developer ID: gh release needs the pushed tag" gh_has "$d" "--verify-tag"
check "Developer ID: feed check passes" grep -qF "Update feed OK" "$d/log"
check "Developer ID: appcast links the release notes" grep -qF \
  "<sparkle:fullReleaseNotesLink>https://github.com/$FEED_REPO/releases/tag/v$(version_of "$d")</sparkle:fullReleaseNotesLink>" \
  "$d/repo/build/appcast.xml"
check "Developer ID: appcast sparkle:version is CFBundleVersion" grep -qF \
  "<sparkle:version>$(plutil -extract CFBundleVersion raw "$d/repo/build/Spacer.app/Contents/Info.plist")</sparkle:version>" \
  "$d/repo/build/appcast.xml"
check "Developer ID: appcast shortVersionString is the version" grep -qF \
  "<sparkle:shortVersionString>$(version_of "$d")</sparkle:shortVersionString>" "$d/repo/build/appcast.xml"

d="$WORK/adhoc"
STATE_MODE=adhoc new_repo "$d"
touch "$d/repo/build/Spacer-PPPC.mobileconfig" # stale profile from an earlier run
touch "$d/repo/build/appcast.xml" # stale appcast from an earlier run
publish "$d" ALLOW_ADHOC=1 STUB_REQUIREMENT='# designated => cdhash H"0123"'
check "ad-hoc: exits 0" test $? -eq 0
check "ad-hoc: tag" has_tag "$d"
check "ad-hoc: gh gets the DMG" gh_has "$d" "build/Spacer-$(version_of "$d").dmg "
check "ad-hoc: gh gets no profile" gh_lacks "$d" "Spacer-PPPC.mobileconfig"
check "ad-hoc: stale profile removed" test ! -e "$d/repo/build/Spacer-PPPC.mobileconfig"
check "ad-hoc: gh gets no appcast" gh_lacks "$d" "appcast.xml"
check "ad-hoc: gh release is not the latest" gh_has "$d" "--latest=false"
check "ad-hoc: stale appcast removed" test ! -e "$d/repo/build/appcast.xml"

d="$WORK/noorigin"
new_repo "$d" noorigin
refused "Developer ID without origin" "$d"
check "Developer ID without origin: no DMG made" no_dmg "$d"

d="$WORK/noorigin-adhoc"
STATE_MODE=adhoc new_repo "$d" noorigin
publish "$d" ALLOW_ADHOC=1 STUB_REQUIREMENT='# designated => cdhash H"0123"'
check "ad-hoc without origin: exits 0" test $? -eq 0
check "ad-hoc without origin: local tag" has_tag "$d"
check "ad-hoc without origin: nothing published" gh_not_called "$d"

d="$WORK/wrong-origin"
ORIGIN_URL="https://github.com/someone-else/Spacer.git" new_repo "$d"
refused "origin is not the feed repo" "$d"
check "origin is not the feed repo: no DMG made" no_dmg "$d"

d="$WORK/ssh-origin"
ORIGIN_URL="git@github.com:$FEED_REPO.git" new_repo "$d"
publish "$d"
check "ssh origin of the feed repo: exits 0" test $? -eq 0

d="$WORK/gh-logged-out"
new_repo "$d"
refused "gh not logged in" "$d" STUB_GH_AUTH=fail
check "gh not logged in: no DMG made" no_dmg "$d"

d="$WORK/release-exists"
new_repo "$d"
refused "GitHub release already exists" "$d" STUB_GH_RELEASE_EXISTS=1
check "GitHub release already exists: no DMG made" no_dmg "$d"

d="$WORK/gh-create-fails"
new_repo "$d"
publish "$d" STUB_GH_CREATE=fail
check "gh release create fails: exits non-zero" test $? -ne 0
check "gh release create fails: tag pushed" origin_has_tag "$d"
check "gh release create fails: prints the command to finish" grep -qF "gh release create v$(version_of "$d")" "$d/log"

d="$WORK/feed-stale"
new_repo "$d"
publish "$d" STUB_FEED=
check "feed not updated yet: still exits 0" test $? -eq 0
check "feed not updated yet: warns" grep -qF "does not serve build" "$d/log"

d="$WORK/profile-fails"
new_repo "$d"
refused "ad-hoc app in Developer ID mode" "$d" STUB_REQUIREMENT='# designated => cdhash H"0123"'

d="$WORK/apple-development"
new_repo "$d"
refused "Apple Development identity" "$d" \
  STUB_IDENTITY="Apple Development: Test (XYZ)" SIGN_IDENTITY="Test"

d="$WORK/rebuilt"
new_repo "$d"
refused "app rebuilt since prepare" "$d" STUB_CDHASH=2222
check "app rebuilt since prepare: no DMG made" no_dmg "$d"

d="$WORK/mode"
STATE_MODE=adhoc new_repo "$d"
refused "prepared ad-hoc, publish Developer ID" "$d"

d="$WORK/staged-during-dmg"
new_repo "$d"
refused "file staged while the DMG is made" "$d" STUB_DMG_STAGE=1

d="$WORK/commit-during-dmg"
new_repo "$d"
publish "$d" STUB_DMG_COMMIT=1
check "commit while the DMG is made: exits non-zero" test $? -ne 0
check "commit while the DMG is made: no tag" no_tag "$d"
check "commit while the DMG is made: release-state kept" state_kept "$d"

d="$WORK/sign-fails"
new_repo "$d"
refused "sign_update fails" "$d" STUB_SIGN=fail
publish "$d"
check "sign_update fails: publish runs again and succeeds" test $? -eq 0

d="$WORK/sign-malformed"
new_repo "$d"
refused "sign_update prints garbage" "$d" STUB_SIGN=malformed

d="$WORK/no-key"
new_repo "$d"
refused "Sparkle key missing" "$d" STUB_NO_KEY=1
check "Sparkle key missing: no DMG made" no_dmg "$d"

d="$WORK/dmg-fails"
new_repo "$d"
refused "DMG or notarization fails" "$d" STUB_DMG_FAIL=1
publish "$d"
check "DMG or notarization fails: publish runs again and succeeds" test $? -eq 0
check "DMG or notarization fails: tag after the rerun" has_tag "$d"

# Notarization (real make-dmg.sh, stub hdiutil and xcrun).
d="$WORK/default-dmg"
REAL_DMG=1 new_repo "$d"
publish "$d"
check "default (NOTARIZE unset): exits 0 with no NOTARY_PROFILE" test $? -eq 0
check "default: release commit" head_is_release "$d"
check "default: tag" has_tag "$d"
check "default: no notarytool or stapler call" notary_not_called "$d"
check "default: gh gets the DMG" gh_has "$d" "build/Spacer-$(version_of "$d").dmg "
check "default: says the DMG is not notarized" grep -qF "is not notarized" "$d/log"

d="$WORK/profile-only"
REAL_DMG=1 new_repo "$d"
publish "$d" NOTARY_PROFILE=test
check "NOTARY_PROFILE without NOTARIZE: exits 0" test $? -eq 0
check "NOTARY_PROFILE without NOTARIZE: no notarytool or stapler call" notary_not_called "$d"

d="$WORK/notarized"
STATE_NOTARIZATION=notarized REAL_DMG=1 new_repo "$d"
publish "$d" NOTARIZE=1 NOTARY_PROFILE=test
check "NOTARIZE=1: exits 0" test $? -eq 0
check "NOTARIZE=1: release commit" head_is_release "$d"
check "NOTARIZE=1: notarytool submit with the profile" xcrun_called "$d" "notarytool submit"
check "NOTARIZE=1: stapler staple" xcrun_called "$d" "stapler staple"
check "NOTARIZE=1: stapler validate" xcrun_called "$d" "stapler validate"
check "NOTARIZE=1: no not-notarized note" test "$(grep -c 'is not notarized' "$d/log")" -eq 0
check "NOTARIZE=1: gh gets the DMG" gh_has "$d" "build/Spacer-$(version_of "$d").dmg "

d="$WORK/notarize-no-profile"
STATE_NOTARIZATION=notarized REAL_DMG=1 new_repo "$d"
refused "NOTARIZE=1 without NOTARY_PROFILE" "$d" NOTARIZE=1
check "NOTARIZE=1 without NOTARY_PROFILE: no DMG made" no_dmg "$d"
check "NOTARIZE=1 without NOTARY_PROFILE: no notarytool call" notary_not_called "$d"

d="$WORK/notarize-adhoc"
STATE_MODE=adhoc STATE_NOTARIZATION=notarized REAL_DMG=1 new_repo "$d"
refused "NOTARIZE=1 with ALLOW_ADHOC=1" "$d" ALLOW_ADHOC=1 NOTARIZE=1 NOTARY_PROFILE=test

d="$WORK/notarize-typo"
REAL_DMG=1 new_repo "$d"
refused "NOTARIZE=yes is rejected" "$d" NOTARIZE=yes NOTARY_PROFILE=test
check "NOTARIZE=yes: no notarytool call" notary_not_called "$d"

d="$WORK/prepared-without-notarize"
REAL_DMG=1 new_repo "$d"
refused "prepared without NOTARIZE, publish with NOTARIZE=1" "$d" NOTARIZE=1 NOTARY_PROFILE=test
check "prepared without NOTARIZE, publish with it: no notarytool call" notary_not_called "$d"

d="$WORK/prepared-notarized"
STATE_NOTARIZATION=notarized REAL_DMG=1 new_repo "$d"
refused "prepared with NOTARIZE=1, publish without" "$d"
check "prepared with NOTARIZE=1, publish without: no notarytool call" notary_not_called "$d"

finish
