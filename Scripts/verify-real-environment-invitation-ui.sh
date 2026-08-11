#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
ios_root="${repo_root}/ios"
real_env_dir="${repo_root}/.real-env"
session_file="${COMINAVI_E2E_SERVICE_SESSION_FILE:-${real_env_dir}/google-recipient-service-session.json}"
invitation_file="${COMINAVI_E2E_INVITATION_FILE:-${real_env_dir}/shared-plan-invitation.json}"
terminal_file="${COMINAVI_E2E_INVITATION_TERMINAL_FILE:-${real_env_dir}/shared-plan-invitation-terminal-states.json}"
simulator_record="${COMINAVI_E2E_RECIPIENT_SIMULATOR_FILE:-${real_env_dir}/recipient-simulator-udid.txt}"
derived_data="${COMINAVI_E2E_DERIVED_DATA:-/tmp/cominavi-recipient-invitation-ui}"
result_bundle_dir="${COMINAVI_E2E_RESULT_BUNDLE_DIR:-}"
run_directory="$(mktemp -d /tmp/cominavi-invitation-ui.XXXXXX)"
generated_xctestruns=()

cleanup() {
  local generated_xctestrun
  for generated_xctestrun in "${generated_xctestruns[@]}"; do
    find "${generated_xctestrun}" -maxdepth 0 -type f -delete 2>/dev/null || true
  done
  find "${run_directory}" -type f -delete 2>/dev/null || true
  rmdir "${run_directory}" 2>/dev/null || true
}
trap cleanup EXIT

umask 077
chmod 700 "${run_directory}"

require_mode_600() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    echo "Missing protected acceptance input: ${path}" >&2
    exit 1
  fi
  local mode
  mode="$(stat -f '%Lp' "${path}")"
  if [[ "${mode}" != "600" ]]; then
    echo "Refusing protected file with mode ${mode}; expected 600: ${path}" >&2
    exit 1
  fi
}

require_mode_600 "${session_file}"
require_mode_600 "${invitation_file}"
require_mode_600 "${simulator_record}"

simulator_udid="$(<"${simulator_record}")"
destination="platform=iOS Simulator,id=${simulator_udid}"

if [[ "${COMINAVI_E2E_AUTHENTICATE_GOOGLE:-0}" == "1" ]]; then
  cd "${ios_root}"
  xcodebuild -quiet \
    -project ComiNavi.xcodeproj \
    -scheme ComiNavi \
    -destination "${destination}" \
    -derivedDataPath "${derived_data}" \
    -parallel-testing-enabled NO \
    -enableCodeCoverage NO \
    build-for-testing
else
  COMINAVI_E2E_SERVICE_SESSION_FILE="${session_file}" \
  COMINAVI_E2E_REPLACE_EXISTING_SERVICE_SESSION=0 \
  COMINAVI_TEST_DESTINATION="${destination}" \
  COMINAVI_E2E_DERIVED_DATA="${derived_data}" \
  "${script_dir}/bootstrap-real-environment-session.sh"
fi

products_dir="${derived_data}/Build/Products"
source_xctestrun="$(find "${products_dir}" -maxdepth 1 -name 'ComiNavi_ComiNavi_*.xctestrun' -print -quit)"
if [[ -z "${source_xctestrun}" ]]; then
  echo "The build did not produce a ComiNavi xctestrun file" >&2
  exit 1
fi

invitation_values="${run_directory}/invitation-values.json"
INVITATION_FILE="${invitation_file}" ruby -rjson -e '
  invitation = JSON.parse(File.read(ENV.fetch("INVITATION_FILE")))
  values = {
    canonicalURL: invitation.fetch("canonicalURL"),
    fallbackURL: invitation.fetch("fallbackURL"),
    planName: "[E2E] Shared Plan Lifecycle v1",
  }
  File.write(ARGV.fetch(0), JSON.generate(values))
  File.chmod(0o600, ARGV.fetch(0))
' "${invitation_values}"

canonical_url="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("canonicalURL")' "${invitation_values}")"
fallback_url="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("fallbackURL")' "${invitation_values}")"

run_ui_assertion() {
  local action="$1"
  local suffix="$2"
  local invitation_url="$3"
  local open_mode="$4"
  local xctestrun_json="${run_directory}/${suffix}.json"
  # __TESTROOT__ is resolved relative to the xctestrun file itself. Keep the
  # generated file beside the build-for-testing product so the UI test runner
  # and app paths remain valid while only the environment is overridden.
  local xctestrun_file="${products_dir}/.cominavi-invitation-ui-${suffix}-$$.xctestrun"
  local result_bundle_args=()
  if [[ -n "${result_bundle_dir}" ]]; then
    mkdir -p "${result_bundle_dir}"
    local result_bundle_run_id="${COMINAVI_E2E_RESULT_BUNDLE_RUN_ID:-$$}"
    local result_bundle_path="${result_bundle_dir}/${suffix}-${result_bundle_run_id}.xcresult"
    if [[ -e "${result_bundle_path}" ]]; then
      echo "Refusing to replace existing result bundle: ${result_bundle_path}" >&2
      exit 1
    fi
    result_bundle_args=(-resultBundlePath "${result_bundle_path}")
  fi
  generated_xctestruns+=("${xctestrun_file}")
  plutil -convert json -o "${xctestrun_json}" "${source_xctestrun}"
  XCTESTRUN_JSON="${xctestrun_json}" INVITATION_VALUES="${invitation_values}" ACTION="${action}" OPEN_URL="${invitation_url}" OPEN_MODE="${open_mode}" ruby -rjson <<'RUBY'
path = ENV.fetch("XCTESTRUN_JSON")
contents = JSON.parse(File.read(path))
targets = contents.fetch("TestConfigurations").fetch(0).fetch("TestTargets")
target = targets.find { |value| value["BlueprintName"] == "ComiNaviUITests" }
abort "ComiNaviUITests target missing from xctestrun" unless target
values = JSON.parse(File.read(ENV.fetch("INVITATION_VALUES")))
environment = target["EnvironmentVariables"] ||= {}
environment["COMINAVI_E2E_INVITATION_UI_REQUIRED"] = "1"
environment["COMINAVI_E2E_INVITATION_UI_ACTION"] = ENV.fetch("ACTION")
environment["COMINAVI_E2E_INVITATION_PLAN_NAME"] = values.fetch("planName")
environment["COMINAVI_E2E_INVITATION_URL"] = ENV.fetch("OPEN_URL")
environment["COMINAVI_E2E_INVITATION_OPEN_MODE"] = ENV.fetch("OPEN_MODE")
File.write(path, JSON.generate(contents))
RUBY
  plutil -convert binary1 -o "${xctestrun_file}" "${xctestrun_json}"
  xcodebuild -quiet \
    -xctestrun "${xctestrun_file}" \
    -destination "${destination}" \
    "${result_bundle_args[@]}" \
    -parallel-testing-enabled NO \
    -enableCodeCoverage NO \
    -collect-test-diagnostics never \
    test-without-building \
    -only-testing:ComiNaviUITests/ComiNaviUITests/testProductionInvitationSurfaceWhenExplicitlyRequired
}

xcrun simctl bootstatus "${simulator_udid}" -b
if [[ "${COMINAVI_E2E_AUTHENTICATE_GOOGLE:-0}" == "1" ]]; then
  run_ui_assertion authenticate-google-accept cold-google-universal-link "${canonical_url}" cold
  echo "Invitation-bound Google authentication and join acceptance passed."
else
  run_ui_assertion dismiss cold-universal-link "${canonical_url}" cold
  run_ui_assertion accept warm-fallback "${fallback_url}" warm

  echo "Cold universal-link, warm fallback, and already-member UI acceptance passed."

  if [[ "${COMINAVI_E2E_VERIFY_TERMINAL_INVITATIONS:-0}" == "1" ]]; then
    require_mode_600 "${terminal_file}"
    terminal_values="${run_directory}/terminal-values.json"
    TERMINAL_FILE="${terminal_file}" ruby -rjson -ruri -e '
      terminal = JSON.parse(File.read(ENV.fetch("TERMINAL_FILE")))
      %w[revokedURL expiredURL].each do |key|
        url = URI.parse(terminal.fetch(key))
        abort "invalid #{key}" unless url.scheme == "https" && url.host == "cominavi.net"
        abort "invalid #{key} path" unless url.path.match?(%r{\A/join/[A-Za-z0-9_-]{12}\z})
      end
      File.write(ARGV.fetch(0), JSON.generate(terminal))
      File.chmod(0o600, ARGV.fetch(0))
    ' "${terminal_values}"
    revoked_url="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("revokedURL")' "${terminal_values}")"
    expired_url="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("expiredURL")' "${terminal_values}")"
    run_ui_assertion expect-unavailable cold-revoked "${revoked_url}" cold
    run_ui_assertion expect-unavailable warm-expired "${expired_url}" warm
    echo "Revoked and expired invitation UI rejection passed."
  fi
fi
