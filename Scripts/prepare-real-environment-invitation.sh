#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
ios_root="${repo_root}/ios"
destination="${COMINAVI_TEST_DESTINATION:-platform=iOS Simulator,name=ComiNavi App Store 6.5}"
simulator_name="${COMINAVI_E2E_SIMULATOR_NAME:-ComiNavi App Store 6.5}"
bundle_id="${COMINAVI_E2E_APP_BUNDLE_ID:-llc.mikunet.cominavi.debug}"
derived_data="${COMINAVI_E2E_DERIVED_DATA:-/tmp/cominavi-simulator-e2e}"
capability_file="${COMINAVI_E2E_INVITATION_FILE:-${repo_root}/.real-env/shared-plan-invitation.json}"
run_directory="$(mktemp -d /tmp/cominavi-invitation.XXXXXX)"

"${script_dir}/bootstrap-real-environment-session.sh"

products_dir="${derived_data}/Build/Products"
source_xctestrun="$(find "${products_dir}" -maxdepth 1 -name 'ComiNavi_ComiNavi_*.xctestrun' -print -quit)"
if [[ -z "${source_xctestrun}" ]]; then
  echo "The build did not produce a ComiNavi xctestrun file" >&2
  exit 1
fi

invitation_xctestrun="${products_dir}/ComiNaviInvitation-$$.xctestrun"
invitation_json="${run_directory}/ComiNaviInvitation.json"
devices_json="${run_directory}/devices.json"
touch "${invitation_xctestrun}" "${invitation_json}" "${devices_json}"
chmod 600 "${invitation_xctestrun}" "${invitation_json}" "${devices_json}"

cleanup() {
  rm -f "${invitation_xctestrun}" "${invitation_json}"
  rm -rf "${run_directory}"
}
trap cleanup EXIT

plutil -convert json -o "${invitation_json}" "${source_xctestrun}"
XCTESTRUN_JSON="${invitation_json}" ruby <<'RUBY'
require "json"

path = ENV.fetch("XCTESTRUN_JSON")
contents = JSON.parse(File.read(path))
targets = contents.fetch("TestConfigurations").fetch(0).fetch("TestTargets")
target = targets.find { |value| value["BlueprintName"] == "ComiNaviTests" }
abort "ComiNaviTests target missing from xctestrun" unless target

environment = target["EnvironmentVariables"] ||= {}
environment["COMINAVI_E2E_SHARED_PLAN_INVITATION_REQUIRED"] = "1"
File.write(path, JSON.generate(contents))
RUBY
plutil -convert binary1 -o "${invitation_xctestrun}" "${invitation_json}"

cd "${ios_root}"
xcodebuild -quiet \
  -xctestrun "${invitation_xctestrun}" \
  -destination "${destination}" \
  -parallel-testing-enabled NO \
  -enableCodeCoverage NO \
  -collect-test-diagnostics never \
  test-without-building \
  -only-testing:ComiNaviTests/RealEnvironmentSharedPlanAcceptanceTests/testPrepareProductionInvitationCapabilityWhenExplicitlyRequired

xcrun simctl list devices available --json >"${devices_json}"
simulator_udid="$({
  SIMULATOR_NAME="${simulator_name}" DEVICES_JSON="${devices_json}" ruby <<'RUBY'
require "json"

name = ENV.fetch("SIMULATOR_NAME")
devices = JSON.parse(File.read(ENV.fetch("DEVICES_JSON"))).fetch("devices")
matches = devices.values.flatten.select { |device| device["name"] == name }
abort "Simulator not found: #{name}" if matches.empty?
booted = matches.find { |device| device["state"] == "Booted" }
puts (booted || matches.first).fetch("udid")
RUBY
})"

app_container="$(xcrun simctl get_app_container "${simulator_udid}" "${bundle_id}" data)"
simulator_capability="${app_container}/Library/Application Support/ComiNaviE2E/shared-plan-invitation.json"
if [[ ! -f "${simulator_capability}" ]]; then
  echo "The invitation test did not produce its protected capability artifact" >&2
  exit 1
fi

mkdir -p "$(dirname "${capability_file}")"
chmod 700 "$(dirname "${capability_file}")"
install -m 600 "${simulator_capability}" "${capability_file}"

INVITATION_FILE="${capability_file}" ruby <<'RUBY'
require "json"
require "uri"

invitation = JSON.parse(File.read(ENV.fetch("INVITATION_FILE")))
url = URI.parse(invitation.fetch("canonicalURL"))
abort "unexpected invitation origin" unless url.scheme == "https" && url.host == "cominavi.net"
abort "unexpected invitation path" unless url.path.match?(%r{\A/join/[A-Za-z0-9_-]{12}\z})
abort "invalid fallback URL" unless invitation.fetch("fallbackURL").start_with?("cominavi://join/")
RUBY

if [[ "${COMINAVI_E2E_COPY_INVITATION_TO_CLIPBOARD:-1}" == "1" ]]; then
  INVITATION_FILE="${capability_file}" ruby -rjson -e \
    'print JSON.parse(File.read(ENV.fetch("INVITATION_FILE"))).fetch("canonicalURL")' \
    | pbcopy
  echo "Copied the protected invitation URL to the Mac clipboard."
fi

echo "Prepared a 24-hour production invitation capability at ${capability_file}."
