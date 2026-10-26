#!/usr/bin/env bash
# Prints or changes the app version in Resources/Info.plist.
#
#   scripts/version.sh                    print "VERSION (BUILD)"
#   scripts/version.sh --short            print VERSION only
#   scripts/version.sh major|minor|patch  bump the version
#   scripts/version.sh X.Y.Z              set the version
#
# Changing the version also increments the build number (CFBundleVersion).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
BUDDY=/usr/libexec/PlistBuddy

version="$("$BUDDY" -c "Print :CFBundleShortVersionString" "$PLIST")"
build="$("$BUDDY" -c "Print :CFBundleVersion" "$PLIST")"

case "${1:-}" in
  "")
    echo "$version ($build)"
    exit 0
    ;;
  --short)
    echo "$version"
    exit 0
    ;;
esac

IFS=. read -r major minor patch <<<"$version"
case "$1" in
  major) next="$((major + 1)).0.0" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  patch) next="$major.$minor.$((patch + 1))" ;;
  *)
    if [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "usage: $0 [--short | major | minor | patch | X.Y.Z]" >&2
      exit 64
    fi
    next="$1"
    ;;
esac

"$BUDDY" -c "Set :CFBundleShortVersionString $next" "$PLIST"
"$BUDDY" -c "Set :CFBundleVersion $((build + 1))" "$PLIST"
echo "$next ($((build + 1)))"
