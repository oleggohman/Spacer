# shellcheck shell=bash
# GitHub Releases helpers shared by make-appcast.sh and release.sh. Source it; it defines
# functions only.
#
# Releases are published to GitHub, and the app finds updates through SUFeedURL in its
# Info.plist: https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml. That URL
# is the one place the repo is named; everything else derives it from there.

# feed_repo PLIST: prints owner/repo from the plist's SUFeedURL, or fails when the feed is not
# a GitHub "latest release" appcast URL.
feed_repo() {
  local feed
  feed="$(plutil -extract SUFeedURL raw "$1" 2>/dev/null)" || return 1
  [[ "$feed" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/latest/download/appcast\.xml$ ]] ||
    return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# remote_repo URL: prints owner/repo for a github.com remote URL (https or ssh, with or
# without .git), or fails for any other URL.
remote_repo() {
  local url="$1"
  url="${url%/}"
  url="${url%.git}"
  case "$url" in
    https://github.com/*) url="${url#https://github.com/}" ;;
    git@github.com:*) url="${url#git@github.com:}" ;;
    ssh://git@github.com/*) url="${url#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
  [[ "$url" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s\n' "$url"
}

# same_repo A B: GitHub owner and repo names are case-insensitive.
same_repo() {
  [[ "$(tr '[:upper:]' '[:lower:]' <<<"$1")" == "$(tr '[:upper:]' '[:lower:]' <<<"$2")" ]]
}
