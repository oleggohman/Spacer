# Spacer

Spacer is a native macOS app that shows disk usage as a nested treemap. It scans a volume or folder and draws each file or folder as a block sized by the space it takes. Folders have a title strip with their name and size and show their children inside. Colors follow the file type; see [Colors and legend](#colors-and-legend).

From the map you can:

- hover a block to see its name and size; the tooltip moves to the other side near the edges
- zoom into folders and go back with the breadcrumb bar, the Go menu or the keyboard (see [Keyboard and mouse](#keyboard-and-mouse))
- select items with the mouse or the arrow keys and see their details in the inspector: path, size, item count, kind, modified date and the 10 largest children
- find items by name with the search field, which highlights matching blocks
- open items, reveal them in Finder or copy their path
- move items to the Trash or delete them permanently. The map updates without a rescan. A banner after a Move to Trash offers Undo, which puts the items back from the Trash and restores them on the map.
- use VoiceOver: each block is read as its name, size and category, and folders offer Zoom In.

Spacer runs outside the App Sandbox. Local builds are ad-hoc signed; releases are signed with a Developer ID certificate, and notarized when cut with `NOTARIZE=1` (see [Releasing](#releasing)).

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6 toolchain)

## Build

```bash
swift build                # debug build
swift test                 # run the tests
scripts/bundle.sh          # release build, wrapped into build/Spacer.app (ad-hoc signed)
scripts/make-icon.sh       # redraws Resources/AppIcon.icns from scripts/make-icon.swift (committed; rerun only when the icon changes)
SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" scripts/bundle.sh   # signed with a Developer ID and the hardened runtime
```

## Run

```bash
open build/Spacer.app
```

Choose a volume in the sidebar, or click "Choose Folder…" to scan any folder. Recent scans are listed in the sidebar. Clicking the volume or folder that is already scanned (or still scanning) shows that map again without scanning. Rescan (Cmd-R) scans the same location again: the previous map stays visible, dimmed, with the progress bar above it, until the new scan finishes. Stop brings the previous map back with its zoom. A scan of another location replaces the map. Spacer keeps only the current scan, plus the previous one while a rescan runs, so memory roughly doubles during that rescan. Stopping a scan that has no previous map discards it, and Spacer goes back to the start screen.

The sidebar shows each disk's used and free space and a bar, the time of the last scan, and the app version and build at the bottom. Above the map, the summary line gives the scanned size and when the scan ran. For a volume it also reads "of 699.8 GB used on Macintosh HD", and "Why different?" explains why the map total can be smaller than the used space. A folder scan shows no used-space figure. The About Spacer item in the app menu shows the version and build.

### What is counted

Sizes are the space each file allocates on disk (`ATTR_FILE_ALLOCSIZE`), so totals can differ from Finder's and from `df`, which also counts snapshots and purgeable space. Hard-linked files count once. APFS clones share their data on disk, so the shared data is counted once: the original counts all its bytes and each clone counts only the bytes that are its own. If the original was deleted, the first surviving clone seen counts the shared data and the others count only their own bytes. This is approximate in two cases: a clone whose original still exists outside the scan shows only its own bytes, and a clone that was edited after cloning counts in full, so the blocks it still shares with its siblings can be counted again. A clone group whose original was truncated or overwritten can be missed (its shared blocks are not counted), and deleting the item that carries a deleted original's shared data updates the totals as if all of it was freed, which can be off until you rescan. Spacer skips symbolic links inside the scan (a scanned folder that is itself a link is scanned at its target). It does not enter other mounted volumes, and when scanning a volume root it skips `/.nofollow` and `/.resolve`, which mirror the whole root, so the same files are not counted twice. Scanning `/` covers the system volume and the data volume, which macOS joins with firmlinks. It draws app bundles in the apps color with their content inside, so you can zoom into them like folders. Files too small to draw are grouped into one "N small items" block, drawn like a folder. Clicking it shows a read-only summary in the inspector; it cannot be selected, opened or deleted.

### Full Disk Access

macOS hides some locations (Mail, Messages, other users' folders, parts of ~/Library) from apps without Full Disk Access. If Spacer cannot read the scan root, it shows a banner with a button that opens the right settings page. Subfolders it cannot read are counted, and a warning line under the summary gives their number. "Show" lists their paths, and the inspector says "Size unknown" for each of them instead of 0 bytes. The warning is collected when the scan finishes. To clear it, grant access:

1. Open System Settings > Privacy & Security > Full Disk Access.
2. Click +, add build/Spacer.app and turn it on.
3. Restart Spacer and rescan.

After you rebuild an ad-hoc signed app, macOS may ask you to grant access again; a Developer ID signed build keeps the grant across rebuilds. On Macs managed with an MDM, the PPPC profile grants access instead; see [Managed Macs](#managed-macs).

## Colors and legend

Each file type has its own flat color, taken from Apple's Storage palette in light and dark mode: Documents red, Photos orange, Music yellow, Developer teal, Apps purple (including app bundles), Video pink, Archives green and Other gray (files with no extension or an unknown type). Labels are white or near-black, whichever reads better on the block.

Folders are neutral: a plain folder is a light gray, a little darker per level in light mode and a little lighter in dark mode, so nesting stays visible without tinting folders by their contents.

The legend bar under the map lists the eight file types with their colors and their share of the folder you are looking at. Images, audio and code are named Photos, Music and Developer there. During a scan it also shows how much of the preview is not listed yet. An app bundle counts as apps in the folder that holds it, so /Applications reads as apps; zoomed into a bundle, the legend shows what the bundle is made of. Click a chip to highlight that file type: matching files and folders keep their color and the rest of the map fades (everything inside an app bundle counts as apps unless you are zoomed into the bundle). Click the chip again to clear the highlight. Chips of file types the folder does not hold are dimmed and cannot be clicked. A new scan clears the highlight. The legend is shown by default. View > Show Legend (Hide Legend) toggles it, with Cmd-L, and hiding it clears the highlight.

## Keyboard and mouse

| Action | Shortcut |
| --- | --- |
| Rescan | Cmd-R |
| Stop scan | Cmd-. (or Esc in the progress overlay) |
| Move keyboard focus to the map | Tab |
| Move the selection to the neighboring block in a direction | Arrow keys |
| Zoom into the selected folder (for a file, its enclosing folder) | Return (double-click works too) |
| Zoom out to the enclosing folder | Cmd-Up arrow, Esc or Backspace |
| Go back / forward | Cmd-[ / Cmd-], or the Back and Forward buttons |
| Show or hide the color legend | Cmd-L (View menu) |
| Move selection to Trash | Cmd-Backspace (asks first) |
| Select a block | Click |
| Clear the selection | Click an empty area |
| Add to or remove from the selection | Cmd-click |
| Zoom into a folder | Double-click |
| Open, Reveal in Finder, Copy Path, Zoom In, delete | Right-click a block |
| Show or hide the inspector | Inspector toolbar button |
| Highlight a file type | Click its chip in the legend |

Map keys (arrows, Return, Esc, Backspace, Cmd-Backspace) act on the map once it has focus, so click it or press Tab first. Cmd-Up, Cmd-[ and Cmd-] are in the Go menu.

## Deletion

Each delete asks for confirmation and shows the item count and total size.

- Move to Trash uses the Finder Trash, so you can restore items from it. A banner under the map then reads "Moved “X” to Trash · 4.2 GB" (or "Moved N items to Trash · 12.4 GB") with an Undo button. Undo puts the items back from the Trash, on disk and on the map. The banner goes away after a few seconds or when you close it; after that, put items back from the Trash in Finder. If an original path is taken again, that item stays in the Trash and Undo reports it as failed.
- Delete Permanently removes items right away, with a banner that reads "Deleted …" and no Undo. It asks a second time, because the items cannot be recovered.

Spacer refuses to delete:

- the scanned folder itself, a volume root and your home folder
- anything under /System, /usr, /bin, /sbin or /Library
- Apple apps in /Applications (including subfolders such as Utilities) and anything inside them
- a folder that contains any of the above, a mounted volume, /Applications, or /etc, /var or /tmp (for example /Users or /private when scanning /)
- anything outside the scanned folder

Items that fail or are refused are listed one by one in an alert. The rest are removed from the map.

## Managed Macs

On Macs managed with an MDM (Jamf, Kandji, Intune and others), a Privacy Preferences Policy Control (PPPC) profile can pre-approve the access Spacer needs, so nobody has to grant it in System Settings. macOS applies PPPC payloads only when an MDM installs them, so upload the profile to your MDM as a custom profile and assign it to the Macs that run Spacer.

The profile has one `com.apple.TCC.configuration-profile-policy` payload. It allows:

| Service | Why |
| --- | --- |
| `SystemPolicyAllFiles` (Full Disk Access) | To size protected locations such as Mail, Messages, Safari and other apps' containers. Without it those folders have no size (the inspector says "Size unknown" and the summary counts them as unreadable), and a scan root Spacer cannot read shows the Full Disk Access banner. |
| `SystemPolicyRemovableVolumes` | To scan external drives without a prompt. |
| `SystemPolicyNetworkVolumes` | To scan network shares without a prompt. |
| `SystemPolicyDesktopFolder`, `SystemPolicyDocumentsFolder`, `SystemPolicyDownloadsFolder` | Full Disk Access already covers these. They are listed so there are no prompts if Full Disk Access is ever removed. |

It grants nothing else: Spacer does not use the camera, microphone, screen recording, Apple Events, accessibility or contacts.

Each entry matches the app by its bundle ID (`com.oleggohman.spacer`) and its designated code requirement. That requirement only stays the same from build to build for a Developer ID signed app, so the profile needs a Developer ID signed build. An ad-hoc build's requirement is a cdhash that changes on every build, and `scripts/make-pppc-profile.sh` refuses it, as well as Apple Development and self-signed builds.

To make the profile:

```bash
SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" scripts/bundle.sh
scripts/make-pppc-profile.sh       # writes build/Spacer-PPPC.mobileconfig
```

The script fills the code requirement into `Resources/Profiles/Spacer-PPPC.mobileconfig.template` and checks the result with `plutil`. `scripts/release.sh publish` makes it from the tested app and attaches `Spacer-PPPC.mobileconfig` to the GitHub release next to the DMG. The profile keeps the identifier `com.oleggohman.spacer.pppc`, so installing a new version replaces the old one instead of adding a second profile. Its payload UUIDs are fixed too, so profiles made from the same signed app are identical files.

The profile only grants access. On a managed Mac the app itself must also be notarized (a release cut with `NOTARIZE=1`), or Gatekeeper blocks it.

## Updates

Spacer updates itself with [Sparkle](https://sparkle-project.org). It checks for a new version once a day, and **Spacer → Check for Updates…** checks right away. The feed is `appcast.xml` on the latest GitHub release, and every update is signed with an EdDSA key whose public half is `SUPublicEDKey` in `Resources/Info.plist`. Builds run with `swift run` skip the updater.

## Releasing

Releases are cut from `main` in two steps, with a manual test in between. They need a signing identity:

- `SIGN_IDENTITY`: a "Developer ID Application" identity in the keychain, by its full name or SHA-1 hash (`security find-identity -v -p codesigning` lists them). `scripts/bundle.sh` signs the app with it, using the hardened runtime and a secure timestamp, and `scripts/make-dmg.sh` signs the DMG with it.

Releases are not notarized by default. Gatekeeper on other Macs blocks a DMG that is not notarized after download, so notarize every release that goes to other Macs. Notarization needs two more variables:

- `NOTARIZE=1`: notarize the DMG and staple the ticket to it. Unset or `0` (the default) skips it.
- `NOTARY_PROFILE`: a notarytool keychain profile, required with `NOTARIZE=1`. Create it once with `xcrun notarytool store-credentials <name> --apple-id <id> --team-id <TEAMID> --password <app-specific-password>`. `scripts/make-dmg.sh` notarizes the DMG with `xcrun notarytool submit --wait`, then staples it. It does nothing with `NOTARY_PROFILE` alone.

`release.sh` stops with an error when `SIGN_IDENTITY` is unset, when `NOTARIZE=1` and `NOTARY_PROFILE` is unset, when `NOTARIZE` is anything other than `1`, `0` or unset, or when the keychain has no Developer ID Application identity that matches `SIGN_IDENTITY`. `prepare` refuses an app that is not signed with a Developer ID. `prepare` records the app's CDHash, the signing mode and the notarization setting in `build/release-state`; `publish` refuses an app with a different CDHash (rebuilt since prepare), a different `ALLOW_ADHOC` setting or a different `NOTARIZE` setting, so set the same variables for both phases.

A signed release, not notarized:

```bash
export SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
scripts/release.sh prepare patch   # or minor, major, X.Y.Z; tests, lint, sets the version, builds and signs build/Spacer.app
open build/Spacer.app              # test the build by hand
scripts/release.sh publish         # writes build/Spacer-PPPC.mobileconfig, builds a signed build/Spacer-X.Y.Z.dmg (not notarized), commits the version, tags vX.Y.Z
```

A notarized release (both phases need `NOTARIZE=1`):

```bash
export SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
export NOTARY_PROFILE=<profile-name>
export NOTARIZE=1
scripts/release.sh prepare patch
open build/Spacer.app
scripts/release.sh publish         # as above, but the DMG is also notarized and stapled
```

`publish` packages the app you tested without rebuilding it. It makes the PPPC profile and the DMG (signing, and with `NOTARIZE=1` notarization and stapling) before it commits and tags, so if any of these fail nothing is committed or tagged, and you can run `publish` again once the cause is fixed. When notarization is rejected, `make-dmg.sh` prints Apple's notarization log. When an `origin` remote exists it also pushes the tag and creates a GitHub release with the DMG, its SHA-256 and `Spacer-PPPC.mobileconfig`; otherwise everything stays local. `ALLOW_ADHOC=1` (set for both `prepare` and `publish`) cuts a local release that is ad-hoc signed, not notarized and without a PPPC profile; on other Macs, open such an app the first time with right-click > Open.

The profile in your MDM only needs updating when the signing identity or the team changes and the app's code requirement changes with it; compare `codesign -dr - build/Spacer.app` with the requirement in the profile. Ordinary version bumps signed with the same Developer ID keep the same requirement, so the profile in your MDM stays as it is. When the identity or team does change, make the profile from a build signed with the new identity and replace the file of the existing custom profile in your MDM instead of adding a second profile.

Other scripts: `scripts/version.sh` prints or changes the version, and `scripts/make-dmg.sh` builds a DMG of the current version (signed when `SIGN_IDENTITY` is set; notarized and stapled only with `NOTARIZE=1` and `NOTARY_PROFILE`). `scripts/make-pppc-profile.sh` is described under [Managed Macs](#managed-macs). Two scripts test the release scripts without a certificate, and `release.sh prepare` runs both: `scripts/test-pppc-profile.sh` runs `make-pppc-profile.sh` with a stub `codesign` on stub apps, and `scripts/test-release.sh` runs `release.sh publish` in throwaway copies of the repo with stub `codesign`, `security`, `gh` and `make-dmg.sh`. `scripts/lib/` holds the shell helpers they share: `signing.sh` (reading the designated requirement and checking that it is Developer ID) and `check.sh` (the test checks).

To check a signed build: `codesign -dr - build/Spacer.app` shows a designated requirement with `anchor apple generic` and the team ID (an ad-hoc build shows a `cdhash` instead). Only the DMG gets the stapled notarization ticket, not `build/Spacer.app`, so `spctl -a -vv build/Spacer.app` reports "accepted" with source "Notarized Developer ID" only when the Mac can look the ticket up online. To check offline, open the DMG and run `spctl -a -vv "/Volumes/Spacer X.Y.Z/Spacer.app"`.
