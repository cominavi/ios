#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
ios_root="${repo_root}/ios"
capability_file="${COMINAVI_E2E_INVITATION_FILE:-${repo_root}/.real-env/shared-plan-invitation.json}"
simulator_name="${COMINAVI_E2E_RECIPIENT_SIMULATOR_NAME:-ComiNavi Invite Recipient 6.5}"
device_type="${COMINAVI_E2E_RECIPIENT_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17e}"
runtime="${COMINAVI_E2E_RECIPIENT_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}"
bundle_id="${COMINAVI_E2E_APP_BUNDLE_ID:-llc.mikunet.cominavi.debug}"
derived_data="${COMINAVI_E2E_DERIVED_DATA:-/tmp/cominavi-simulator-e2e}"
simulator_record="${COMINAVI_E2E_RECIPIENT_SIMULATOR_FILE:-${repo_root}/.real-env/recipient-simulator-udid.txt}"
devices_json="$(mktemp /tmp/cominavi-recipient-devices.XXXXXX)"

cleanup() {
  rm -f "${devices_json}"
}
trap cleanup EXIT
chmod 600 "${devices_json}"

if [[ ! -f "${capability_file}" ]]; then
  echo "Missing invitation capability: ${capability_file}" >&2
  exit 1
fi
if [[ "$(stat -f '%Lp' "${capability_file}")" != "600" ]]; then
  echo "Refusing invitation capability that is not mode 600" >&2
  exit 1
fi

xcrun simctl list devices available --json >"${devices_json}"
simulator_udid="$({
  SIMULATOR_NAME="${simulator_name}" DEVICES_JSON="${devices_json}" ruby <<'RUBY'
require "json"

name = ENV.fetch("SIMULATOR_NAME")
devices = JSON.parse(File.read(ENV.fetch("DEVICES_JSON"))).fetch("devices")
match = devices.values.flatten.find { |device| device["name"] == name }
puts match.fetch("udid") if match
RUBY
})"
if [[ -z "${simulator_udid}" ]]; then
  simulator_udid="$(xcrun simctl create "${simulator_name}" "${device_type}" "${runtime}")"
fi

mkdir -p "$(dirname "${simulator_record}")"
chmod 700 "$(dirname "${simulator_record}")"
printf '%s\n' "${simulator_udid}" >"${simulator_record}"
chmod 600 "${simulator_record}"

if ! xcrun simctl boot "${simulator_udid}" 2>/dev/null; then
  # `boot` exits nonzero when an existing preserved Simulator is already up.
  xcrun simctl list devices | rg -F "${simulator_udid}" >/dev/null
fi
xcrun simctl bootstatus "${simulator_udid}" -b

cd "${ios_root}"
xcodebuild -quiet \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi \
  -destination "platform=iOS Simulator,id=${simulator_udid}" \
  -derivedDataPath "${derived_data}" \
  -parallel-testing-enabled NO \
  build

app_path="${derived_data}/Build/Products/Debug-iphonesimulator/ComiNavi.app"
if [[ ! -d "${app_path}" ]]; then
  echo "ComiNavi build product is missing: ${app_path}" >&2
  exit 1
fi
xcrun simctl install "${simulator_udid}" "${app_path}"

invitation_url="$({
  INVITATION_FILE="${capability_file}" ruby <<'RUBY'
require "json"
require "uri"

invitation = JSON.parse(File.read(ENV.fetch("INVITATION_FILE")))
url = URI.parse(invitation.fetch("canonicalURL"))
abort "unexpected invitation origin" unless url.scheme == "https" && url.host == "cominavi.net"
abort "unexpected invitation path" unless url.path.match?(%r{\A/join/[A-Za-z0-9_-]{12}\z})
print url.to_s
RUBY
})"

open -a Simulator --args -CurrentDeviceUDID "${simulator_udid}"
xcrun simctl openurl "${simulator_udid}" "${invitation_url}"

echo "Opened the protected invitation on preserved recipient Simulator ${simulator_name}."
