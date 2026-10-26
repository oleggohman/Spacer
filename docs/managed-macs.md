# Managed Macs

On Macs managed with an MDM (Jamf, Kandji, Intune and others), a PPPC (Privacy Preferences Policy Control) profile pre-approves the access Spacer needs, so nobody has to grant it in System Settings. Each release has `Spacer-PPPC.mobileconfig` attached; upload it to your MDM as a custom profile.

It allows:

| Service | Why |
| --- | --- |
| `SystemPolicyAllFiles` (Full Disk Access) | to size protected locations such as Mail, Messages and app containers |
| `SystemPolicyRemovableVolumes`, `SystemPolicyNetworkVolumes` | to scan external drives and network shares without a prompt |
| `SystemPolicyDesktopFolder`, `SystemPolicyDocumentsFolder`, `SystemPolicyDownloadsFolder` | no prompts if Full Disk Access is ever removed |

Nothing else: no camera, microphone, screen recording, Apple Events, accessibility or contacts.

The profile matches the app by bundle ID (`com.oleggohman.spacer`) and its Developer ID code requirement, so it keeps working across versions signed by the same team. Replace it in your MDM only if the signing team changes.

To make it from your own Developer ID build:

```bash
SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" scripts/bundle.sh
scripts/make-pppc-profile.sh   # writes build/Spacer-PPPC.mobileconfig
```
