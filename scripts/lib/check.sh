# shellcheck shell=bash
# Check helpers shared by the shell test scripts. Source it, run `check` for each case and end
# with `finish`.

FAILURES=0

# check NAME CONDITION...: runs CONDITION and reports it as ok or FAIL.
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok: $name"
  else
    echo "FAIL: $name"
    FAILURES=$((FAILURES + 1))
  fi
}

# finish: prints the summary and exits non-zero when any check failed.
finish() {
  if [[ "$FAILURES" -ne 0 ]]; then
    echo "$FAILURES check(s) failed"
    exit 1
  fi
  echo "all checks passed"
}
