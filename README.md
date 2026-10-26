# Spacer

A native macOS app that shows disk usage as a treemap. Scan a disk or folder, see what takes the space, and clean it up.

- Every file and folder is a block sized by the space it takes, colored by type (documents, photos, music, video, apps, archives, developer files).
- Zoom into folders, search by name, and see details in the inspector.
- Open, reveal in Finder, move to the Trash (with Undo) or delete permanently. The map updates without a rescan.
- Guard rails: Spacer refuses to delete system folders, Apple apps, your home folder and the scanned folder itself.
- Works with VoiceOver.

## Install

Download the latest `Spacer-X.Y.Z.dmg` from [Releases](https://github.com/oleggohman/Spacer/releases/latest) and drag Spacer to Applications. Releases are signed and notarized. Spacer checks for updates daily (Spacer → Check for Updates… checks now).

Requires macOS 15 or later.

## Full Disk Access

macOS hides some locations (Mail, Messages, parts of ~/Library) from apps without Full Disk Access. Spacer counts folders it can't read and lists them under the summary. To size them too, turn Spacer on in System Settings → Privacy & Security → Full Disk Access, then restart it. Some system folders stay unreadable even with access; that is expected.

Managed Macs can get access through an MDM profile; see [docs/managed-macs.md](docs/managed-macs.md).

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Rescan (the zoomed folder only, when zoomed in) | Cmd-R |
| Stop scan | Cmd-. |
| Zoom in / out | Return or double-click / Esc or Cmd-Up |
| Back / forward | Cmd-[ / Cmd-] |
| Move the selection | Arrow keys |
| Move to Trash | Cmd-Backspace |
| Show or hide the legend | Cmd-L |

Right-click a block for Open, Reveal in Finder, Copy Path and delete.

## Build from source

Needs Xcode 16 or later (Swift 6).

```bash
swift build && swift test
scripts/bundle.sh        # release build in build/Spacer.app (ad-hoc signed)
open build/Spacer.app
```

Releasing is described in [docs/release-process.md](docs/release-process.md).

## Notes on sizes

Sizes are the space files allocate on disk, so totals can differ from Finder and `df` (which also count snapshots and purgeable space). Hard links and APFS clones are counted once, symbolic links and other mounted volumes are skipped.
