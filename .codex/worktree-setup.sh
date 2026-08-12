#!/usr/bin/env bash
# Provision a newly-created Codex worktree without modifying the source
# checkout. Codex provides CODEX_WORKTREE_PATH after the Git worktree exists.
set -euo pipefail

fail() {
  printf 'ComiNavi worktree setup: %s\n' "$*" >&2
  exit 1
}

worktree="${CODEX_WORKTREE_PATH:-$PWD}"
source_tree="${CODEX_SOURCE_TREE_PATH:-$worktree}"
[[ -d "$worktree" ]] || fail "worktree does not exist: $worktree"
[[ -d "$source_tree" ]] || fail "source checkout does not exist: $source_tree"
[[ "$(uname -s)" == "Darwin" ]] || fail 'native iOS development requires macOS.'
command -v xcodebuild >/dev/null 2>&1 || fail 'xcodebuild is unavailable; install Xcode and select it with xcode-select.'
command -v xcrun >/dev/null 2>&1 || fail 'xcrun is unavailable; install Xcode Command Line Tools.'

xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
xcode_major="${xcode_version%%.*}"
[[ "$xcode_major" =~ ^[0-9]+$ ]] || fail "could not determine the Xcode version: $xcode_version"
(( xcode_major >= 16 )) || fail "Xcode 16 or later is required; found Xcode $xcode_version."
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 || fail 'the iOS Simulator SDK is not installed for the selected Xcode.'

[[ -f "$worktree/ComiNavi.xcodeproj/project.pbxproj" ]] || fail 'ComiNavi.xcodeproj is missing from the worktree.'
[[ -f "$worktree/ComiNavi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" ]] || fail 'the committed Package.resolved file is missing.'
[ -e "$worktree/.codegraph/codegraph.db" ] || codegraph init "$worktree"

printf 'ComiNavi worktree setup: Xcode %s; resolving locked Swift packages...\n' "$xcode_version"
(
  cd "$worktree"
  CODEX_WORKTREE_PATH="$worktree" bash "$source_tree/.codex/xcode.sh" resolve
)
printf 'ComiNavi worktree setup: ready at %s\n' "$worktree"
