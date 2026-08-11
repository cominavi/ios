#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
ios_root="${repo_root}/ios"
destination="${COMINAVI_TEST_DESTINATION:-platform=iOS Simulator,name=ComiNavi App Store 6.5}"
derived_data="${COMINAVI_E2E_DERIVED_DATA:-/tmp/cominavi-simulator-e2e}"
run_directory="$(mktemp -d /tmp/cominavi-real-environment.XXXXXX)"

"${script_dir}/bootstrap-real-environment-session.sh"

products_dir="${derived_data}/Build/Products"
source_xctestrun="$(find "${products_dir}" -maxdepth 1 -name 'ComiNavi_ComiNavi_*.xctestrun' -print -quit)"
if [[ -z "${source_xctestrun}" ]]; then
  echo "The build did not produce a ComiNavi xctestrun file" >&2
  exit 1
fi

lifecycle_xctestrun="${products_dir}/ComiNaviLifecycle-$$.xctestrun"
lifecycle_json="${run_directory}/ComiNaviLifecycle.json"
touch "${lifecycle_xctestrun}" "${lifecycle_json}"
chmod 600 "${lifecycle_xctestrun}" "${lifecycle_json}"

cleanup() {
  rm -f "${lifecycle_xctestrun}" "${lifecycle_json}"
}
trap cleanup EXIT

plutil -convert json -o "${lifecycle_json}" "${source_xctestrun}"
XCTESTRUN_JSON="${lifecycle_json}" ruby <<'RUBY'
require "json"

path = ENV.fetch("XCTESTRUN_JSON")
contents = JSON.parse(File.read(path))
targets = contents.fetch("TestConfigurations").fetch(0).fetch("TestTargets")
target = targets.find { |value| value["BlueprintName"] == "ComiNaviTests" }
abort "ComiNaviTests target missing from xctestrun" unless target

environment = target["EnvironmentVariables"] ||= {}
environment["COMINAVI_E2E_SHARED_PLAN_LIFECYCLE_REQUIRED"] = "1"
File.write(path, JSON.generate(contents))
RUBY
plutil -convert binary1 -o "${lifecycle_xctestrun}" "${lifecycle_json}"

cd "${ios_root}"
xcodebuild \
  -xctestrun "${lifecycle_xctestrun}" \
  -destination "${destination}" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage NO \
  -collect-test-diagnostics never \
  -resultBundlePath "${run_directory}/SharedPlanLifecycle.xcresult" \
  test-without-building \
  -only-testing:ComiNaviTests/RealEnvironmentSharedPlanAcceptanceTests/testProductionCreateListArchiveReopenLifecycleWhenExplicitlyRequired

xcodebuild \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi \
  -destination "${destination}" \
  -derivedDataPath "${derived_data}" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage NO \
  -collect-test-diagnostics never \
  -resultBundlePath "${run_directory}/C108Catalog.xcresult" \
  test-without-building \
  -only-testing:ComiNaviUITests/ComiNaviUITests/testLiveProductionC108CatalogDownloadsAndOpens

echo "Real-environment acceptance passed. Results: ${run_directory}"
