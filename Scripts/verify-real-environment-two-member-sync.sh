#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
ios_root="${repo_root}/ios"
real_env_dir="${repo_root}/.real-env"
owner_session="${COMINAVI_E2E_OWNER_SESSION_FILE:-${real_env_dir}/cominavi-service-session.json}"
recipient_session="${COMINAVI_E2E_RECIPIENT_SESSION_FILE:-${real_env_dir}/google-recipient-service-session.json}"
simulator_record="${COMINAVI_E2E_TWO_MEMBER_SIMULATOR_FILE:-${real_env_dir}/two-member-e2e-simulator-udid.txt}"
derived_data="${COMINAVI_E2E_DERIVED_DATA:-/tmp/cominavi-two-member-e2e}"
result_bundle="${COMINAVI_E2E_RESULT_BUNDLE_PATH:-}"
bundle_id="${COMINAVI_E2E_APP_BUNDLE_ID:-llc.mikunet.cominavi.debug}"
run_directory="$(mktemp -d /tmp/cominavi-two-member-e2e.XXXXXX)"
generated_xctestrun=""
generated_json=""
owner_export_name="cominavi-owner-session-$(ruby -rsecurerandom -e 'print SecureRandom.hex(16)').json"
recipient_export_name="cominavi-recipient-session-$(ruby -rsecurerandom -e 'print SecureRandom.hex(16)').json"

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
require_mode_600 "${recipient_session}"
require_mode_600 "${simulator_record}"

ruby -rjson -rtime -e '
  owner = JSON.parse(File.read(ARGV.fetch(0)))
  recipient = JSON.parse(File.read(ARGV.fetch(1)))
  abort "missing owner user binding" unless owner.dig("user", "id").is_a?(String)
  abort "missing recipient user binding" unless recipient.dig("user", "id").is_a?(String)
  abort "two-member test requires distinct users" if owner.dig("user", "id") == recipient.dig("user", "id")
  [owner, recipient].each do |session|
    abort "invalid bearer session" unless session["tokenType"].to_s.downcase == "bearer"
    refresh = session["refreshToken"]
    abort "missing refresh authority" unless refresh.is_a?(String) && refresh.match?(/\A[A-Za-z0-9_-]{43}\z/)
    abort "expired refresh authority" unless Time.iso8601(session.fetch("refreshExpiresAt")) > Time.now
  end
' "${owner_session}" "${recipient_session}"

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

generated_json="${run_directory}/two-member.json"
generated_xctestrun="${products_dir}/.cominavi-two-member-$$.xctestrun"
plutil -convert json -o "${generated_json}" "${source_xctestrun}"
OWNER_SESSION="${owner_session}" \
RECIPIENT_SESSION="${recipient_session}" \
OWNER_EXPORT_NAME="${owner_export_name}" \
RECIPIENT_EXPORT_NAME="${recipient_export_name}" \
XCTESTRUN_JSON="${generated_json}" \
ruby -rbase64 -rjson <<'RUBY'
path = ENV.fetch("XCTESTRUN_JSON")
contents = JSON.parse(File.read(path))
targets = contents.fetch("TestConfigurations").fetch(0).fetch("TestTargets")
target = targets.find { |value| value["BlueprintName"] == "ComiNaviTests" }
abort "ComiNaviTests target missing from xctestrun" unless target
environment = target["EnvironmentVariables"] ||= {}
environment["COMINAVI_E2E_TWO_MEMBER_SYNC_REQUIRED"] = "1"
environment["COMINAVI_E2E_OWNER_SESSION_BASE64"] = Base64.strict_encode64(
  File.binread(ENV.fetch("OWNER_SESSION"))
)
environment["COMINAVI_E2E_RECIPIENT_SESSION_BASE64"] = Base64.strict_encode64(
  File.binread(ENV.fetch("RECIPIENT_SESSION"))
)
environment["COMINAVI_E2E_OWNER_SESSION_EXPORT_NAME"] = ENV.fetch("OWNER_EXPORT_NAME")
environment["COMINAVI_E2E_RECIPIENT_SESSION_EXPORT_NAME"] = ENV.fetch("RECIPIENT_EXPORT_NAME")
File.write(path, JSON.generate(contents))
RUBY
plutil -convert binary1 -o "${generated_xctestrun}" "${generated_json}"
chmod 600 "${generated_xctestrun}"

set +e
test_arguments=(
  -quiet
  -xctestrun "${generated_xctestrun}"
  -destination "${destination}"
  -parallel-testing-enabled NO
  -enableCodeCoverage NO
  -collect-test-diagnostics never
)
if [[ -n "${result_bundle}" ]]; then
  test_arguments+=(-resultBundlePath "${result_bundle}")
fi
test_arguments+=(
  test-without-building
  -only-testing:ComiNaviTests/RealEnvironmentSharedPlanAcceptanceTests/testProductionTwoMemberOfflineRelaunchConvergenceWhenExplicitlyRequired
)
xcodebuild "${test_arguments[@]}"
test_status=$?
set -e

# Xcode may return the Simulator to its prior shutdown state immediately after
# the hosted test. Recover the protected successor artifacts by booting that
# same preserved device instead of abandoning potentially rotated sessions.
if ! data_container="$(xcrun simctl get_app_container "${simulator_udid}" "${bundle_id}" data 2>/dev/null)"; then
  xcrun simctl boot "${simulator_udid}" 2>/dev/null || true
  xcrun simctl bootstatus "${simulator_udid}" -b
  data_container="$(xcrun simctl get_app_container "${simulator_udid}" "${bundle_id}" data)"
fi
export_directory="${data_container}/Library/Application Support/CominaviE2EExports"

install_successor() {
  local existing="$1"
  local exported="$2"
  local replacement="${existing}.replacement.$$"
  require_mode_600 "${exported}"
  EXISTING_SESSION="${existing}" EXPORTED_SESSION="${exported}" ruby -rjson -rtime <<'RUBY'
existing = JSON.parse(File.read(ENV.fetch("EXISTING_SESSION")))
exported = JSON.parse(File.read(ENV.fetch("EXPORTED_SESSION")))
abort "session user mismatch" unless existing.dig("user", "id") == exported.dig("user", "id")
abort "invalid successor bearer" unless exported["tokenType"].to_s.downcase == "bearer"
abort "invalid successor access token" unless exported["accessToken"].is_a?(String) && !exported["accessToken"].empty?
refresh = exported["refreshToken"]
abort "invalid successor refresh token" unless refresh.is_a?(String) && refresh.match?(/\A[A-Za-z0-9_-]{43}\z/)
abort "expired successor refresh token" unless Time.iso8601(exported.fetch("refreshExpiresAt")) > Time.now
RUBY
  install -m 600 "${exported}" "${replacement}"
  mv "${replacement}" "${existing}"
  find "${exported}" -maxdepth 0 -type f -delete
}

# The stores write every refresh rotation immediately. Preserve successors even
# when a later acceptance assertion fails, so an exact test retry never reuses a
# consumed refresh token.
install_successor "${owner_session}" "${export_directory}/${owner_export_name}"
install_successor "${recipient_session}" "${export_directory}/${recipient_export_name}"

if [[ "${test_status}" -ne 0 ]]; then
  echo "Two-member production acceptance failed; rotated sessions were still preserved." >&2
  exit "${test_status}"
fi

echo "Two-member offline, relaunch, reconnect, convergence, and inbox acceptance passed."
