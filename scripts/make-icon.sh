#!/usr/bin/env bash
# Renders the app icon and writes Resources/AppIcon.icns, which bundle.sh copies into the app.
# The icon is committed, so bundle.sh does not render it on every build. Run this again only
# when scripts/make-icon.swift changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ICONSET="$TMPDIR/Spacer.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"

echo "Wrote $ROOT/Resources/AppIcon.icns"
