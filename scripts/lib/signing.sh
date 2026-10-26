# shellcheck shell=bash
# Code signature helpers shared by bundle.sh, make-dmg.sh, make-pppc-profile.sh and release.sh.
# Source it; it defines a constant and functions only.

# Parts every Developer ID designated requirement has: Apple's anchor, the Developer ID
# intermediate, the Developer ID Application leaf and the team ID. Apple Development,
# self-signed and ad-hoc requirements lack at least one of them.
DEVELOPER_ID_PARTS=(
  'anchor apple generic'
  'certificate 1[field.1.2.840.113635.100.6.2.6]'
  'certificate leaf[field.1.2.840.113635.100.6.1.13]'
  'certificate leaf[subject.OU]'
)

# notarize_requested: succeeds when NOTARIZE=1 asks for the DMG to be notarized and stapled.
# Scripts reject other values before they call it, so a typo cannot skip notarization.
notarize_requested() {
  [[ "${NOTARIZE:-}" == 1 ]]
}

# designated_requirement: reads `codesign -dr -` output on stdin and prints the designated
# requirement (nothing when there is none).
designated_requirement() {
  sed -n 's/^#* *designated => //p'
}

# is_developer_id_requirement REQUIREMENT: succeeds when it is a Developer ID Application
# requirement.
is_developer_id_requirement() {
  local part
  [[ -n "$1" ]] || return 1
  for part in "${DEVELOPER_ID_PARTS[@]}"; do
    [[ "$1" == *"$part"* ]] || return 1
  done
}

# is_developer_id_signed APP: succeeds when the app's designated requirement is a Developer ID
# Application requirement.
is_developer_id_signed() {
  local info
  info="$(codesign -dr - "$1" 2>&1)" || return 1
  is_developer_id_requirement "$(printf '%s\n' "$info" | designated_requirement)"
}
