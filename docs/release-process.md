# Releasing

Releases are published to [GitHub Releases](https://github.com/oleggohman/Spacer/releases). Each release carries:

- `Spacer-X.Y.Z.dmg` and its `.sha256`: the signed, notarized app
- `appcast.xml`: the Sparkle update feed
- `Spacer-PPPC.mobileconfig`: the profile for managed Macs ([managed-macs.md](managed-macs.md))

Installed copies read `https://github.com/oleggohman/Spacer/releases/latest/download/appcast.xml` (`SUFeedURL` in `Resources/Info.plist`), so publishing a release is what ships the update. That URL is also the one place the repo is named: the scripts derive `owner/repo` from it.

## One-time setup

- A **Developer ID Application** certificate in the keychain (`security find-identity -v -p codesigning`).
- A **notarytool profile**: `xcrun notarytool store-credentials <name> --apple-id <id> --team-id <TEAMID> --password <app-specific-password>`.
- The **Sparkle EdDSA key** in the login keychain, account `com.oleggohman.spacer`. Its public half is `SUPublicEDKey` in `Info.plist`. Back up the private key (`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.oleggohman.spacer -x key-backup`) and keep it safe: without it, installed copies can never be updated again.
- `gh auth login`, and `origin` pointing at the repo in `SUFeedURL`.

## Cut a release

```bash
export SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
export NOTARY_PROFILE=<name> NOTARIZE=1
scripts/release.sh prepare patch   # or minor, major, X.Y.Z
open build/Spacer.app              # test it by hand
scripts/release.sh publish
```

`prepare` checks the signing identity, `origin`, `gh` and the Sparkle key, runs the tests, lint and a strict build, bumps the version and build number, and builds the signed app.

`publish` ships exactly the app you tested (it checks its CDHash):

1. writes the PPPC profile, builds the DMG, signs, notarizes and staples it
2. signs the DMG for Sparkle and writes `build/appcast.xml`
3. commits the version, tags `vX.Y.Z`, pushes both
4. creates the GitHub release with the files above
5. checks that the live feed serves the new build

Anything that fails before step 3 leaves no commit or tag; fix it and run `publish` again. If creating the release fails after the push, `publish` prints the `gh release create` command that finishes it.

The first update to reach users needs a version that already contains Sparkle; 0.2.0 does not, so 0.2.1 must be installed by hand once.

## Script tests

`scripts/test-release.sh` and `scripts/test-pppc-profile.sh` run the release scripts against stubs (no certificate, Apple or GitHub needed). `prepare` runs both.
