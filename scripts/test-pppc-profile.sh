#!/usr/bin/env bash
# Checks scripts/make-pppc-profile.sh without a Developer ID certificate: a stub `codesign`
# on PATH returns the signature to test, and stub apps carry only an Info.plist.
# Exits non-zero when any check fails.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/make-pppc-profile.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spacer-pppc-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=scripts/lib/check.sh
source "$ROOT/scripts/lib/check.sh"
# The services the template grants, listed here rather than parsed from it, so a parsing bug
# in the script cannot hide here too (PPPCProfileTemplateTests holds the template to this list).
SERVICES=(
  SystemPolicyAllFiles SystemPolicyRemovableVolumes SystemPolicyNetworkVolumes
  SystemPolicyDesktopFolder SystemPolicyDocumentsFolder SystemPolicyDownloadsFolder
)

TEAM="ABCDE12345"
APP_ID="$(plutil -extract CFBundleIdentifier raw "$ROOT/Resources/Info.plist")"
DEVELOPER_ID="identifier \"$APP_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = $TEAM"

mkdir -p "$WORK/bin"
cat >"$WORK/bin/codesign" <<'EOF'
#!/usr/bin/env bash
# Stub: --verify exits with STUB_VERIFY_STATUS; -dr prints STUB_REQUIREMENT or exits with
# STUB_READ_STATUS.
case "$1" in
  --verify)
    [[ "${STUB_VERIFY_STATUS:-0}" == 0 ]] || echo "stub: invalid signature" >&2
    exit "${STUB_VERIFY_STATUS:-0}"
    ;;
  -dr)
    if [[ "${STUB_READ_STATUS:-0}" != 0 ]]; then
      echo "stub: code object is not signed at all" >&2
      exit "$STUB_READ_STATUS"
    fi
    echo "Executable=$3/Contents/MacOS/Spacer" >&2
    printf '%s\n' "$STUB_REQUIREMENT"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$WORK/bin/codesign"

make_app() { # make_app DIR BUNDLE_ID
  mkdir -p "$1/Contents"
  cp "$ROOT/Resources/Info.plist" "$1/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
}
make_app "$WORK/Spacer.app" "$APP_ID"
make_app "$WORK/Other.app" "com.example.other"

# run APP OUT REQUIREMENT [VAR=VALUE...]: runs the script with the stub, returns its status.
run() {
  local app="$1" out="$2" requirement="$3"
  shift 3
  rm -f "$out"
  env PATH="$WORK/bin:$PATH" STUB_REQUIREMENT="$requirement" "$@" \
    "$SCRIPT" "$app" "$out" >"$WORK/log" 2>&1
}

refused() { # refused NAME APP REQUIREMENT [VAR=VALUE...]: the script must fail and write nothing.
  local name="$1" out="$WORK/refused.mobileconfig"
  shift
  run "$1" "$out" "${@:2}"
  local status=$?
  check "$name: exits non-zero" test "$status" -ne 0
  check "$name: writes no profile" test ! -e "$out"
}

no_placeholder() { ! grep -q __CODE_REQUIREMENT__ "$1"; }

# A Developer ID requirement, including characters that need XML escaping.
for requirement in \
  "designated => $DEVELOPER_ID" \
  "# designated => $DEVELOPER_ID and (info[Note] = \"a&b<c>'d\")"; do
  out="$WORK/Spacer-PPPC.mobileconfig"
  run "$WORK/Spacer.app" "$out" "$requirement"
  status=$?
  expected="${requirement#\# }"
  expected="${expected#designated => }"
  check "Developer ID requirement ($expected): exits 0" test "$status" -eq 0
  check "Developer ID requirement: profile is a valid plist" plutil -lint -s "$out"
  check "Developer ID requirement: no placeholder left" no_placeholder "$out"
  for service in "${SERVICES[@]}"; do
    got="$(/usr/libexec/PlistBuddy -c "Print :PayloadContent:0:Services:$service:0:CodeRequirement" "$out" 2>/dev/null)"
    check "Developer ID requirement: $service carries the requirement" test "$got" == "$expected"
  done
done

refused "ad-hoc (cdhash) requirement" "$WORK/Spacer.app" '# designated => cdhash H"0123456789abcdef"'
refused "Apple Development requirement" "$WORK/Spacer.app" \
  "designated => identifier \"$APP_ID\" and anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: Test (XYZ)\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
refused "self-signed requirement" "$WORK/Spacer.app" \
  "designated => identifier \"$APP_ID\" and certificate root = H\"a1fb64aab7a4441436d50b91f310bf8c3dafc22c\""
refused "requirement for another identifier" "$WORK/Spacer.app" \
  "designated => ${DEVELOPER_ID/identifier \"$APP_ID\"/identifier \"com.example.other\"}"
refused "no designated requirement" "$WORK/Spacer.app" "Executable=x"
refused "unreadable signature" "$WORK/Spacer.app" "designated => $DEVELOPER_ID" STUB_READ_STATUS=1
refused "invalid signature" "$WORK/Spacer.app" "designated => $DEVELOPER_ID" STUB_VERIFY_STATUS=1
refused "other bundle ID" "$WORK/Other.app" "designated => $DEVELOPER_ID"
refused "missing app" "$WORK/Missing.app" "designated => $DEVELOPER_ID"

finish
