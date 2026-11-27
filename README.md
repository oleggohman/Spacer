# Spacer

Spacer is a native macOS app that draws your disk as a treemap. Scan a drive or a folder, see at a glance what takes the space, and clean it up without leaving the map.

Requires macOS 15 or later. Signed and notarized by Apple.

## Install

1. Download the latest `Spacer-X.Y.Z-notarized.dmg` from [Releases](https://github.com/oleggohman/Spacer/releases/latest).
2. Open it and drag Spacer to Applications.

Spacer checks for updates once a day and installs them through Sparkle. To check now, choose **Spacer → Check for Updates…**.

## What it does

- **See where the space went.** Every file and folder is a block sized by the space it takes on disk. Files are colored by type (documents, photos, music, video, apps, archives, developer files and other). Folders stay neutral, so the files inside them stand out.
- **Find the big things fast.** The legend under the map shows how much each type takes in the current view. Click a type to highlight its blocks and fade the rest.
- **Move around.** Double-click a folder or press Return to zoom in, Esc to zoom out, and go Back and Forward like in a browser. Search by name from the toolbar.
- **Inspect.** The inspector shows the selection's size, item count, kind, modification date and path, plus its ten largest items.
- **Clean up in place.** Open, show in Finder, copy the path, move to the Trash (with Undo) or delete permanently. The map updates at once, without a rescan.
- **Stay safe.** Spacer refuses to delete the scanned folder itself, volume roots, your home folder, system folders (`/System`, `/usr`, `/bin`, `/sbin`, `/Library`), Apple apps, and any folder that contains one of these.
- **Manage drives.** The sidebar lists your disks with used and free space, and your recent scans. Eject disk images and external drives from there.
- **Scan fast.** Spacer reads folders in bulk and draws a live preview of the map while it scans. Rescan the whole disk, or only the folder you zoomed into.
- **Use it your way.** Full keyboard navigation and VoiceOver support. Every map color keeps a 4.5:1 contrast with its label, in light and dark mode.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Rescan (only the zoomed folder, when zoomed in) | ⌘R |
| Stop the scan | ⌘. |
| Zoom in | Return or double-click |
| Zoom out | Esc or ⌘↑ |
| Back / Forward | ⌘[ / ⌘] |
| Move the selection | Arrow keys |
| Move to Trash | ⌘⌫ |
| Show or hide the legend | ⌘L |

Right-click a block for Open, Reveal in Finder, Copy Path, Zoom In, Move to Trash and Delete Permanently.

## Full Disk Access

macOS hides some locations (Mail, Messages, parts of `~/Library`) from apps without Full Disk Access. Spacer does not guess their size: it lists the folders it could not read under the scan summary.

To include them, turn Spacer on in **System Settings → Privacy & Security → Full Disk Access** and restart it. A few system folders stay unreadable even then; that is expected.

On Macs managed by MDM, IT can grant the access with the PPPC profile attached to every release. See [docs/managed-macs.md](docs/managed-macs.md).

## How sizes are counted

Spacer shows the space files take on disk (allocated size), not their logical length:

- Hard links count once.
- APFS clones count only the bytes they do not share with the original.
- Symbolic links and other mounted volumes are skipped.
- Cloud placeholders (iCloud Drive, Google Drive and other File Provider folders whose content is not on this Mac) are skipped, so a scan never downloads them.

Totals can therefore differ from Finder and `df`, which also count local snapshots and purgeable space.

## Build from source

Spacer is a Swift package (Swift 6, strict concurrency) with no Xcode project. You need Xcode 16 or later.

```bash
swift build
swift test
scripts/bundle.sh          # release build in build/Spacer.app (ad-hoc signed)
open build/Spacer.app
```

| Path | Contents |
| --- | --- |
| `Sources/SpacerCore` | All the logic: scanner, file tree, treemap layout, deletion guard rails, app state |
| `Sources/Spacer` | Thin SwiftUI views and the Sparkle updater |
| `Tests/SpacerCoreTests` | Swift Testing tests for SpacerCore |
| `scripts/` | Bundling, DMG, signing, appcast and release scripts |

Before sending a change, run:

```bash
swift test
swift format lint --recursive --strict Sources Tests
swift build -c release -Xswiftc -warnings-as-errors
```

Releases (signing, notarization, the Sparkle feed and GitHub Releases) are described in [docs/release-process.md](docs/release-process.md).
