#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
ios_root="${repo_root}/ios"
real_env_dir="${repo_root}/.real-env"
owner_session="${COMINAVI_E2E_OWNER_SESSION_FILE:-${real_env_dir}/cominavi-service-session.json}"
invitation_file="${COMINAVI_E2E_INVITATION_FILE:-${real_env_dir}/shared-plan-invitation.json}"
terminal_file="${COMINAVI_E2E_INVITATION_TERMINAL_FILE:-${real_env_dir}/shared-plan-invitation-terminal-states.json}"
simulator_record="${COMINAVI_E2E_TWO_MEMBER_SIMULATOR_FILE:-${real_env_dir}/two-member-e2e-simulator-udid.txt}"
derived_data="${COMINAVI_E2E_DERIVED_DATA:-/tmp/cominavi-invitation-terminal-states}"
result_bundle_dir="${COMINAVI_E2E_RESULT_BUNDLE_DIR:-}"
bundle_id="${COMINAVI_E2E_APP_BUNDLE_ID:-llc.mikunet.cominavi.debug}"
run_directory="$(mktemp -d /tmp/cominavi-invitation-terminal.XXXXXX)"
generated_xctestrun=""
generated_json=""
owner_export_name="cominavi-owner-session-$(ruby -rsecurerandom -e 'print SecureRandom.hex(16)').json"
terminal_export_name="cominavi-invitation-terminal-$(ruby -rsecurerandom -e 'print SecureRandom.hex(16)').json"
replacement_export_name="cominavi-invitation-replacement-$(ruby -rsecurerandom -e 'print SecureRandom.hex(16)').json"
owner_successor_installed=0

umask 077
chmod 700 "${run_directory}"

cleanup() {
  [[ -z "${generated_xctestrun}" ]] || find "${generated_xctestrun}" -maxdepth 0 -type f -delete 2>/dev/null || true
  [[ -z "${generated_json}" ]] || find "${generated_json}" -maxdepth 0 -type f -delete 2>/dev/null || true
  find "${run_directory}" -type f -delete 2>/dev/null || true
  rmdir "${run_directory}" 2>/dev/null || true
}
trap cleanup EXIT

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

require_mode_600 "${owner_session}"
require_mode_600 "${invitation_file}"
require_mode_600 "${simulator_record}"

OWNER_SESSION="${owner_session}" INVITATION_FILE="${invitation_file}" ruby -rjson -rtime <<'RUBY'
owner = JSON.parse(File.read(ENV.fetch("OWNER_SESSION")))
abort "missing owner user binding" unless owner.dig("user", "id").is_a?(String)
abort "invalid owner bearer" unless owner["tokenType"].to_s.downcase == "bearer"
refresh = owner["refreshToken"]
abort "missing owner refresh authority" unless refresh.is_a?(String) && refresh.match?(/\A[A-Za-z0-9_-]{43}\z/)
abort "expired owner refresh authority" unless Time.iso8601(owner.fetch("refreshExpiresAt")) > Time.now

invitation = JSON.parse(File.read(ENV.fetch("INVITATION_FILE")))
abort "missing invitation plan" unless invitation["planID"].is_a?(String)
abort "invalid invitation token" unless invitation["token"].to_s.match?(/\A[A-Za-z0-9_-]{12}\z/)
RUBY

simulator_udid="$(<"${simulator_record}")"
destination="platform=iOS Simulator,id=${simulator_udid}"

cd "${ios_root}"
xcodebuild -quiet \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi \
  -destination "${destination}" \
  -derivedDataPath "${derived_data}" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage NO \
  build-for-testing

products_dir="${derived_data}/Build/Products"
source_xctestrun="$(find "${products_dir}" -maxdepth 1 -name 'ComiNavi_ComiNavi_*.xctestrun' -print -quit)"
if [[ -z "${source_xctestrun}" ]]; then
  echo "The build did not produce a ComiNavi xctestrun file" >&2
  exit 1
fi

generated_json="${run_directory}/invitation-terminal.json"
generated_xctestrun="${products_dir}/.cominavi-invitation-terminal-$$.xctestrun"
plutil -convert json -o "${generated_json}" "${source_xctestrun}"
OWNER_SESSION="${owner_session}" \
INVITATION_FILE="${invitation_file}" \
OWNER_EXPORT_NAME="${owner_export_name}" \
TERMINAL_EXPORT_NAME="${terminal_export_name}" \
REPLACEMENT_EXPORT_NAME="${replacement_export_name}" \
XCTESTRUN_JSON="${generated_json}" \
ruby -rbase64 -rjson <<'RUBY'
path = ENV.fetch("XCTESTRUN_JSON")
contents = JSON.parse(File.read(path))
targets = contents.fetch("TestConfigurations").fetch(0).fetch("TestTargets")
target = targets.find { |value| value["BlueprintName"] == "ComiNaviTests" }
abort "ComiNaviTests target missing from xctestrun" unless target
environment = target["EnvironmentVariables"] ||= {}
environment["COMINAVI_E2E_INVITATION_TERMINAL_STATES_REQUIRED"] = "1"
environment["COMINAVI_E2E_OWNER_SESSION_BASE64"] = Base64.strict_encode64(
  File.binread(ENV.fetch("OWNER_SESSION"))
)
environment["COMINAVI_E2E_INVITATION_BASE64"] = Base64.strict_encode64(
  File.binread(ENV.fetch("INVITATION_FILE"))
)
environment["COMINAVI_E2E_OWNER_SESSION_EXPORT_NAME"] = ENV.fetch("OWNER_EXPORT_NAME")
environment["COMINAVI_E2E_INVITATION_TERMINAL_EXPORT_NAME"] = ENV.fetch("TERMINAL_EXPORT_NAME")
environment["COMINAVI_E2E_INVITATION_REPLACEMENT_EXPORT_NAME"] = ENV.fetch("REPLACEMENT_EXPORT_NAME")
File.write(path, JSON.generate(contents))
RUBY
plutil -convert binary1 -o "${generated_xctestrun}" "${generated_json}"
chmod 600 "${generated_xctestrun}"

set +e
result_bundle_args=()
if [[ -n "${result_bundle_dir}" ]]; then
  mkdir -p "${result_bundle_dir}"
  result_bundle_path="${result_bundle_dir}/terminal-state-preparation-$$.xcresult"
  if [[ -e "${result_bundle_path}" ]]; then
    echo "Refusing to replace existing result bundle: ${result_bundle_path}" >&2
    exit 1
  fi
  result_bundle_args=(-resultBundlePath "${result_bundle_path}")
fi
xcodebuild -quiet \
  -xctestrun "${generated_xctestrun}" \
  -destination "${destination}" \
  "${result_bundle_args[@]}" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage NO \
  -collect-test-diagnostics never \
  test-without-building \
  -only-testing:ComiNaviTests/RealEnvironmentSharedPlanAcceptanceTests/testPrepareProductionInvitationRevocationAndExpiryWhenExplicitlyRequired
test_status=$?
set -e

data_container="$(xcrun simctl get_app_container "${simulator_udid}" "${bundle_id}" data)"
export_directory="${data_container}/Library/Application Support/CominaviE2EExports"

install_owner_successor_if_present() {
  local exported="${export_directory}/${owner_export_name}"
  if [[ ! -f "${exported}" ]]; then
    return
  fi
  require_mode_600 "${exported}"
  EXISTING_SESSION="${owner_session}" EXPORTED_SESSION="${exported}" ruby -rjson -rtime <<'RUBY'
existing = JSON.parse(File.read(ENV.fetch("EXISTING_SESSION")))
exported = JSON.parse(File.read(ENV.fetch("EXPORTED_SESSION")))
abort "session user mismatch" unless existing.dig("user", "id") == exported.dig("user", "id")
abort "invalid successor bearer" unless exported["tokenType"].to_s.downcase == "bearer"
abort "invalid successor access token" unless exported["accessToken"].is_a?(String) && !exported["accessToken"].empty?
refresh = exported["refreshToken"]
abort "invalid successor refresh token" unless refresh.is_a?(String) && refresh.match?(/\A[A-Za-z0-9_-]{43}\z/)
abort "expired successor refresh token" unless Time.iso8601(exported.fetch("refreshExpiresAt")) > Time.now
RUBY
  local replacement="${owner_session}.replacement.$$"
  install -m 600 "${exported}" "${replacement}"
  mv "${replacement}" "${owner_session}"
  find "${exported}" -maxdepth 0 -type f -delete
  owner_successor_installed=1
}

# The XCTest store writes its initial value before the first request and every
# rotated successor before publishing it in memory. Preserve that file even if
# a later terminal-state assertion fails.
install_owner_successor_if_present

if [[ "${test_status}" -ne 0 ]]; then
  echo "Invitation terminal-state preparation failed; any rotated owner session was preserved." >&2
  exit "${test_status}"
fi
if [[ "${owner_successor_installed}" -ne 1 ]]; then
  echo "The successful invitation test did not export its protected owner session." >&2
  exit 1
fi

terminal_export="${export_directory}/${terminal_export_name}"
replacement_export="${export_directory}/${replacement_export_name}"
require_mode_600 "${terminal_export}"
require_mode_600 "${replacement_export}"

TERMINAL_EXPORT="${terminal_export}" REPLACEMENT_EXPORT="${replacement_export}" ruby -rjson -rtime -ruri <<'RUBY'
terminal = JSON.parse(File.read(ENV.fetch("TERMINAL_EXPORT")))
abort "missing terminal plan name" unless terminal["planName"].is_a?(String) && !terminal["planName"].empty?
["revokedURL", "expiredURL"].each do |key|
  url = URI.parse(terminal.fetch(key))
  abort "invalid #{key}" unless url.scheme == "https" && url.host == "cominavi.net" && url.path.match?(%r{\A/join/[A-Za-z0-9_-]{12}\z})
end

replacement = JSON.parse(File.read(ENV.fetch("REPLACEMENT_EXPORT")))
abort "invalid replacement token" unless replacement["token"].to_s.match?(/\A[A-Za-z0-9_-]{12}\z/)
abort "expired replacement" unless Time.iso8601(replacement.fetch("expiresAt")) > Time.now
canonical = URI.parse(replacement.fetch("canonicalURL"))
fallback = URI.parse(replacement.fetch("fallbackURL"))
abort "invalid replacement canonical URL" unless canonical.scheme == "https" && canonical.host == "cominavi.net" && canonical.path == "/join/#{replacement.fetch("token")}"
abort "invalid replacement fallback URL" unless fallback.scheme == "cominavi" && fallback.host == "join" && fallback.path == "/#{replacement.fetch("token")}"
RUBY

mkdir -p "${real_env_dir}"
chmod 700 "${real_env_dir}"
terminal_replacement="${terminal_file}.replacement.$$"
invitation_replacement="${invitation_file}.replacement.$$"
install -m 600 "${terminal_export}" "${terminal_replacement}"
install -m 600 "${replacement_export}" "${invitation_replacement}"
mv "${terminal_replacement}" "${terminal_file}"
mv "${invitation_replacement}" "${invitation_file}"
find "${terminal_export}" "${replacement_export}" -maxdepth 0 -type f -delete

echo "Prepared protected revoked and expired invitation evidence at ${terminal_file}."
echo "Installed a fresh active replacement invitation at ${invitation_file}."
