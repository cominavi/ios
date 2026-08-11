#!/usr/bin/env bash
# Reproducible command-line Xcode entry points used by Codex actions.
set -euo pipefail

fail() {
  printf 'ComiNavi Xcode action: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${CODEX_WORKTREE_PATH:-$(cd "$script_dir/.." && pwd)}"
derived_data="${COMINAVI_DERIVED_DATA_PATH:-$repo/DerivedData}"
source_packages="$derived_data/SourcePackages"
action="${1:-}"

[[ -n "$action" ]] || fail 'expected one of: resolve, build, test.'
command -v xcodebuild >/dev/null 2>&1 || fail 'xcodebuild is unavailable.'
mkdir -p "$derived_data"

common=(
  -project "$repo/ComiNavi.xcodeproj"
  -scheme ComiNavi
  -clonedSourcePackagesDirPath "$source_packages"
  -derivedDataPath "$derived_data"
  -disableAutomaticPackageResolution
  -skipPackageUpdates
  # The project intentionally runs Apple's pinned OpenAPIGenerator build
  # plugin. Codex actions are noninteractive, so they cannot accept Xcode's
  # first-use trust prompt. Keep this bypass local to these locked CLI builds.
  -skipPackagePluginValidation
)

case "$action" in
  resolve)
    exec xcodebuild "${common[@]}" -resolvePackageDependencies
    ;;
  build)
    exec xcodebuild \
      "${common[@]}" \
      -destination 'generic/platform=iOS Simulator' \
      CODE_SIGNING_ALLOWED=NO \
      build
    ;;
  test)
    destination="${COMINAVI_TEST_DESTINATION:-}"
    if [[ -z "$destination" ]]; then
      device_id="$(
        xcrun simctl list devices available |
          awk -F '[()]' '
            /iPhone/ {
              if (first == "") first = $2
              if ($0 ~ /Booted/ && booted == "") booted = $2
            }
            END { print booted != "" ? booted : first }
          '
      )"
      [[ -n "$device_id" ]] || fail 'no available iPhone Simulator was found; set COMINAVI_TEST_DESTINATION to override.'
      destination="platform=iOS Simulator,id=$device_id"
    fi
    exec xcodebuild \
      "${common[@]}" \
      -destination "$destination" \
      CODE_SIGNING_ALLOWED=NO \
      test
    ;;
  *)
    fail "unknown action '$action'; expected one of: resolve, build, test."
    ;;
esac
