#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
real_env_dir="${repo_root}/.real-env"
session_file="${COMINAVI_E2E_SERVICE_SESSION_FILE:-${real_env_dir}/google-recipient-service-session.json}"
simulator_record="${COMINAVI_E2E_RECIPIENT_SIMULATOR_FILE:-${real_env_dir}/recipient-simulator-udid.txt}"
derived_data="${COMINAVI_E2E_DERIVED_DATA:-/tmp/cominavi-recipient-session-export}"
result_bundle="${COMINAVI_E2E_RESULT_BUNDLE_PATH:-}"
bundle_id="${COMINAVI_E2E_APP_BUNDLE_ID:-llc.mikunet.cominavi.debug}"
export_name="cominavi-session-export-$(ruby -rsecurerandom -e 'print SecureRandom.hex(16)').json"
bootstrap_xctestrun=""
bootstrap_json=""
replacement="${session_file}.replacement.$$"
simulator_export=""

cleanup() {
  [[ -z "${bootstrap_xctestrun}" ]] || find "${bootstrap_xctestrun}" -maxdepth 0 -type f -delete 2>/dev/null || true
  [[ -z "${bootstrap_json}" ]] || find "${bootstrap_json}" -maxdepth 0 -type f -delete 2>/dev/null || true
  [[ -z "${replacement}" ]] || find "${replacement}" -maxdepth 0 -type f -delete 2>/dev/null || true
  [[ -z "${simulator_export}" ]] || find "${simulator_export}" -maxdepth 0 -type f -delete 2>/dev/null || true
}
trap cleanup EXIT

umask 077

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
require_mode_600 "${simulator_record}"

simulator_udid="$(<"${simulator_record}")"
destination="platform=iOS Simulator,id=${simulator_udid}"

cd "${repo_root}/ios"
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

bootstrap_xctestrun="${products_dir}/ComiNaviSessionExport-$$.xctestrun"
bootstrap_json="$(mktemp /tmp/cominavi-session-export.XXXXXX)"
touch "${bootstrap_xctestrun}"
chmod 600 "${bootstrap_xctestrun}" "${bootstrap_json}"

plutil -convert json -o "${bootstrap_json}" "${source_xctestrun}"
XCTESTRUN_JSON="${bootstrap_json}" EXPORT_NAME="${export_name}" ruby -rjson <<'RUBY'
path = ENV.fetch("XCTESTRUN_JSON")
contents = JSON.parse(File.read(path))
targets = contents.fetch("TestConfigurations").fetch(0).fetch("TestTargets")
target = targets.find { |value| value["BlueprintName"] == "ComiNaviTests" }
abort "ComiNaviTests target missing from xctestrun" unless target
environment = target["EnvironmentVariables"] ||= {}
environment["COMINAVI_E2E_EXPORT_SERVICE_SESSION_REQUIRED"] = "1"
environment["COMINAVI_E2E_SESSION_BRIDGE_ACTIVE"] = "1"
environment["COMINAVI_E2E_EXPORT_SERVICE_SESSION_FILE_NAME"] = ENV.fetch("EXPORT_NAME")
File.write(path, JSON.generate(contents))
RUBY
plutil -convert binary1 -o "${bootstrap_xctestrun}" "${bootstrap_json}"

test_arguments=(
  -quiet
  -xctestrun "${bootstrap_xctestrun}"
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
  -only-testing:ComiNaviTests/RealEnvironmentSessionBootstrapTests/testExportProductionSessionWhenExplicitlyRequired
)
xcodebuild "${test_arguments[@]}"

data_container="$(xcrun simctl get_app_container "${simulator_udid}" "${bundle_id}" data)"
simulator_export="${data_container}/Library/Application Support/CominaviE2EExports/${export_name}"
require_mode_600 "${simulator_export}"

EXISTING_SESSION="${session_file}" EXPORTED_SESSION="${simulator_export}" ruby -rjson -rtime <<'RUBY'
existing = JSON.parse(File.read(ENV.fetch("EXISTING_SESSION")))
exported = JSON.parse(File.read(ENV.fetch("EXPORTED_SESSION")))
existing_user = existing.dig("user", "id")
exported_user = exported.dig("user", "id")
abort "session user mismatch" unless existing_user.is_a?(String) && existing_user == exported_user
abort "invalid bearer session" unless exported["tokenType"].to_s.downcase == "bearer"
abort "invalid access token" unless exported["accessToken"].is_a?(String) && !exported["accessToken"].empty?
refresh = exported["refreshToken"]
abort "invalid refresh token" unless refresh.is_a?(String) && refresh.match?(/\A[A-Za-z0-9_-]{43}\z/)
abort "expired refresh token" unless Time.iso8601(exported.fetch("refreshExpiresAt")) > Time.now
abort "invalid auth version" unless exported["authVersion"].is_a?(Integer) && exported["authVersion"] > 0
RUBY

install -m 600 "${simulator_export}" "${replacement}"
mv "${replacement}" "${session_file}"
chmod 600 "${session_file}"
find "${simulator_export}" -maxdepth 0 -type f -delete
rmdir "$(dirname "${simulator_export}")" 2>/dev/null || true
simulator_export=""

echo "Saved the Simulator's current ComiNavi session into the protected real-environment state."
