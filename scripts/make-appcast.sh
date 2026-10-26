#!/usr/bin/env bash
# Writes the Sparkle appcast for one release: an RSS feed with a single item for the DMG,
# signed with the release's EdDSA key. The app reads it from SUFeedURL in Info.plist
# (https://github.com/<repo>/releases/latest/download/appcast.xml), so each GitHub release
# carries the appcast for itself and "latest" always points at the newest one.
#
#   scripts/make-appcast.sh DMG NOTES OUT [APP]
#
# DMG    the final (signed, notarized and stapled) DMG; it must not change after this runs.
# NOTES  release notes, one "- change" line per change (other lines are left out).
# OUT    where to write the appcast.
# APP    the packaged app the DMG holds; version, build and minimum macOS are read from its
#        Info.plist (default: build/Spacer.app), not from the working tree.
#
# The GitHub repo (owner/name) comes from the app's SUFeedURL; see scripts/lib/github.sh.
# SPARKLE_SIGN_UPDATE  Sparkle's sign_update tool (default: the one SwiftPM downloaded).
# SPARKLE_KEY_ACCOUNT  keychain account of the EdDSA private key (default: the bundle ID).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/github.sh
source "$ROOT/scripts/lib/github.sh"

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ "$#" == 3 || "$#" == 4 ]] || fail "usage: $0 DMG NOTES OUT [APP]"
DMG="$1" NOTES="$2" OUT="$3" APP="${4:-$ROOT/build/Spacer.app}"
[[ -f "$DMG" ]] || fail "$DMG not found"
[[ -f "$NOTES" ]] || fail "$NOTES not found"

PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || fail "$PLIST not found"
plist_value() { plutil -extract "$1" raw "$PLIST"; }
VERSION="$(plist_value CFBundleShortVersionString)"
BUILD="$(plist_value CFBundleVersion)"
MIN_SYSTEM="$(plist_value LSMinimumSystemVersion)"
REPO="$(feed_repo "$PLIST")" ||
  fail "SUFeedURL in $PLIST is not https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml"
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
ACCOUNT="${SPARKLE_KEY_ACCOUNT:-$(plist_value CFBundleIdentifier)}"
[[ -x "$SIGN_UPDATE" ]] || fail "$SIGN_UPDATE not found; run swift package resolve first"

# sign_update prints the item's attributes: sparkle:edSignature="..." length="...".
attributes="$("$SIGN_UPDATE" --account "$ACCOUNT" "$DMG")" || fail "sign_update failed for $DMG"
[[ "$attributes" == *'sparkle:edSignature="'*'length="'* ]] ||
  fail "unexpected sign_update output: $attributes"

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}
changes="$(sed -n 's/^- //p' "$NOTES" | xml_escape | sed 's|.*|        <li>&</li>|')"
url="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")"
notes_url="https://github.com/$REPO/releases/tag/v$VERSION"

cat >"$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Spacer</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Spacer $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$notes_url</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
      <ul>
$changes
      </ul>
      ]]></description>
      <enclosure url="$url" type="application/octet-stream" $attributes/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$OUT" || fail "$OUT is not well-formed XML"
echo "Wrote $OUT for Spacer $VERSION ($BUILD)"
