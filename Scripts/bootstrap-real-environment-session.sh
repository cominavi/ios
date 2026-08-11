#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
ios_root="${repo_root}/ios"
session_file="${COMINAVI_E2E_SERVICE_SESSION_FILE:-${repo_root}/.real-env/cominavi-service-session.json}"
destination="${COMINAVI_TEST_DESTINATION:-platform=iOS Simulator,name=ComiNavi App Store 6.5}"
derived_data="${COMINAVI_E2E_DERIVED_DATA:-/tmp/cominavi-simulator-e2e}"
result_bundle="${COMINAVI_E2E_BOOTSTRAP_RESULT_BUNDLE_PATH:-}"

if [[ ! -f "${session_file}" ]]; then
  echo "Missing ComiNavi service session: ${session_file}" >&2
  exit 1
fi

session_mode="$(stat -f '%Lp' "${session_file}")"
if [[ "${session_mode}" != "600" ]]; then
  echo "Refusing session file with mode ${session_mode}; expected 600" >&2
  exit 1
fi

cd "${ios_root}"
xcodebuild -quiet \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi \
  -destination "${destination}" \
  -derivedDataPath "${derived_data}" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage NO \
  -skipPackagePluginValidation \
  build-for-testing

products_dir="${derived_data}/Build/Products"
source_xctestrun="$(find "${products_dir}" -maxdepth 1 -name 'ComiNavi_ComiNavi_*.xctestrun' -print -quit)"
if [[ -z "${source_xctestrun}" ]]; then
  echo "The build did not produce a ComiNavi xctestrun file" >&2
  exit 1
fi

bootstrap_xctestrun="${products_dir}/ComiNaviSessionBootstrap-$$.xctestrun"
bootstrap_json="$(mktemp /tmp/cominavi-session-bootstrap.XXXXXX)"
touch "${bootstrap_xctestrun}"
chmod 600 "${bootstrap_xctestrun}" "${bootstrap_json}"

cleanup() {
  rm -f "${bootstrap_xctestrun}" "${bootstrap_json}"
}
trap cleanup EXIT

plutil -convert json -o "${bootstrap_json}" "${source_xctestrun}"
SESSION_FILE="${session_file}" XCTESTRUN_JSON="${bootstrap_json}" ruby <<'RUBY'
require "base64"
require "json"

path = ENV.fetch("XCTESTRUN_JSON")
contents = JSON.parse(File.read(path))
targets = contents.fetch("TestConfigurations").fetch(0).fetch("TestTargets")
target = targets.find { |value| value["BlueprintName"] == "ComiNaviTests" }
abort "ComiNaviTests target missing from xctestrun" unless target

environment = target["EnvironmentVariables"] ||= {}
environment["COMINAVI_E2E_SERVICE_SESSION_REQUIRED"] = "1"
environment["COMINAVI_E2E_SESSION_BRIDGE_ACTIVE"] = "1"
environment["COMINAVI_E2E_SERVICE_SESSION_BASE64"] = Base64.strict_encode64(
  File.binread(ENV.fetch("SESSION_FILE"))
)
if ENV["COMINAVI_E2E_REPLACE_EXISTING_SERVICE_SESSION"] == "1"
  environment["COMINAVI_E2E_REPLACE_EXISTING_SERVICE_SESSION"] = "1"
end
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
  -only-testing:ComiNaviTests/RealEnvironmentSessionBootstrapTests/testInstallProductionSessionWhenExplicitlyRequired
)
xcodebuild "${test_arguments[@]}"

echo "Installed the production ComiNavi service session into the dedicated Simulator Keychain."
