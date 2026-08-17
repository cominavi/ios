#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
release_branch="$(git -C "${repo_root}" branch --show-current)"
source_commit="$(git -C "${repo_root}" rev-parse HEAD)"
build_directory="${repo_root}/build/fastlane"
operation_status_path="${build_directory}/operation-status.json"
operation_id="testflight-$(date -u +%Y%m%dT%H%M%SZ)-${source_commit:0:8}"
key_path="${ASC_KEY_FILEPATH:-${repo_root}/fastlane/AuthKey_672X4QRBR9.p8}"
dry_run=0

if [[ "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: Scripts/publish-external-testflight.sh [--dry-run] [fastlane lane options]

Builds the committed main-branch snapshot, uploads it to TestFlight, submits it
to the External Beta group, enables tester notifications, and verifies the live
App Store Connect state. Uncommitted checkout changes are not included.

Examples:
  Scripts/publish-external-testflight.sh
  Scripts/publish-external-testflight.sh group:"External Beta"
  Scripts/publish-external-testflight.sh --dry-run
USAGE
  exit 0
fi

if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
  shift
fi

if [[ "${release_branch}" != "main" && "${COMINAVI_ALLOW_NON_MAIN_RELEASE:-0}" != "1" ]]; then
  echo "Refusing to publish branch '${release_branch:-detached HEAD}'." >&2
  echo "Merge to main first, or set COMINAVI_ALLOW_NON_MAIN_RELEASE=1 intentionally." >&2
  exit 1
fi

if [[ ! -r "${key_path}" ]]; then
  echo "App Store Connect API key is not readable at ${key_path}." >&2
  exit 1
fi

for notes_path in \
  "${repo_root}/fastlane/testflight/what_to_test/ja.txt" \
  "${repo_root}/fastlane/testflight/what_to_test/en-US.txt"
do
  if [[ ! -s "${notes_path}" ]]; then
    echo "TestFlight notes are missing or empty: ${notes_path}" >&2
    exit 1
  fi
done

locked_fastlane_version="$(
  awk '/^    fastlane \([0-9]/{gsub(/[()]/, "", $2); print $2; exit}' \
    "${repo_root}/Gemfile.lock"
)"

if command -v bundle >/dev/null 2>&1 && (
  cd "${repo_root}"
  bundle check >/dev/null 2>&1
); then
  fastlane_command=(bundle exec fastlane)
elif command -v fastlane >/dev/null 2>&1; then
  installed_fastlane_version="$(
    fastlane --version 2>/dev/null \
      | awk '$1 == "fastlane" && $2 ~ /^[0-9]/{version=$2} END{print version}'
  )"
  if [[ "${installed_fastlane_version}" != "${locked_fastlane_version}" ]]; then
    echo "Fastlane ${locked_fastlane_version} is locked, but ${installed_fastlane_version:-none} is installed." >&2
    exit 1
  fi
  fastlane_command=(fastlane)
else
  echo "Fastlane is unavailable. Install the locked dependencies with bundle install." >&2
  exit 1
fi

if ! git -C "${repo_root}" diff --quiet || ! git -C "${repo_root}" diff --cached --quiet; then
  echo "Note: uncommitted changes are excluded; publishing commit ${source_commit}."
fi

echo "Source: ${source_commit} (${release_branch:-detached HEAD})"
echo "Artifacts: ${build_directory}"
echo "Command: ${fastlane_command[*]} ios external_beta $*"

if [[ "${dry_run}" == "1" ]]; then
  exit 0
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/cominavi-testflight.XXXXXX")"
release_worktree="${temporary_root}/source"
worktree_added=0

cleanup() {
  exit_status=$?
  if [[ "${exit_status}" -ne 0 ]] && \
    ! jq -e '.state == "failed"' "${operation_status_path}" >/dev/null 2>&1
  then
    COMINAVI_OPERATION_ID="${operation_id}" \
    COMINAVI_OPERATION_STATUS_PATH="${operation_status_path}" \
      "${repo_root}/Scripts/cominavi-ops" record testflight \
        --state failed \
        --stage failed \
        --message "TestFlight publisher exited before completion." \
        --error "Exit status ${exit_status}." >/dev/null 2>&1 || true
  fi
  if [[ "${worktree_added}" == "1" ]]; then
    git -C "${repo_root}" worktree remove --force "${release_worktree}" >/dev/null 2>&1 || true
  fi
  rmdir "${temporary_root}" >/dev/null 2>&1 || true
  trap - EXIT
  exit "${exit_status}"
}
trap cleanup EXIT

COMINAVI_OPERATION_ID="${operation_id}" \
COMINAVI_OPERATION_STATUS_PATH="${operation_status_path}" \
  "${repo_root}/Scripts/cominavi-ops" record testflight \
    --state running \
    --stage preparing \
    --message "Preparing committed source for the external TestFlight release."

git -C "${repo_root}" worktree add --detach "${release_worktree}" "${source_commit}"
worktree_added=1

mkdir -p "${build_directory}"
cd "${release_worktree}"
ASC_KEY_FILEPATH="${key_path}" \
COMINAVI_FASTLANE_BUILD_DIRECTORY="${build_directory}" \
COMINAVI_OPERATION_ID="${operation_id}" \
COMINAVI_OPERATION_STATUS_PATH="${operation_status_path}" \
FASTLANE_SKIP_UPDATE_CHECK=1 \
  "${fastlane_command[@]}" ios external_beta "$@"
