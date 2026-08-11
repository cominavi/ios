#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
real_env_dir="${repo_root}/.real-env"
service_origin="${COMINAVI_E2E_SERVICE_ORIGIN:-https://cominavi.net}"
session_file="${COMINAVI_E2E_SERVICE_SESSION_FILE:-${real_env_dir}/cominavi-service-session.json}"
temporary_directory="$(mktemp -d /tmp/cominavi-session-refresh.XXXXXX)"

cleanup() {
  find "${temporary_directory}" -type f -delete 2>/dev/null || true
  rmdir "${temporary_directory}" 2>/dev/null || true
}
trap cleanup EXIT

umask 077
chmod 700 "${temporary_directory}"

case "${service_origin}" in
  https://cominavi.net) ;;
  *)
    echo "Refusing non-production ComiNavi service origin: ${service_origin}" >&2
    exit 1
    ;;
esac

if [[ ! -f "${session_file}" ]]; then
  echo "Missing protected ComiNavi session: ${session_file}" >&2
  exit 1
fi
if [[ "$(stat -f '%Lp' "${session_file}")" != "600" ]]; then
  echo "Refusing a session file that is not mode 0600: ${session_file}" >&2
  exit 1
fi

request_file="${temporary_directory}/request.json"
response_file="${session_file}.refresh-response.$$"
profile_file="${temporary_directory}/profile.json"
curl_config="${temporary_directory}/curl.conf"

SESSION_FILE="${session_file}" REQUEST_FILE="${request_file}" ruby -rjson -rtime <<'RUBY'
session = JSON.parse(File.read(ENV.fetch("SESSION_FILE")))
refresh = session["refreshToken"]
abort "missing refresh authority" unless refresh.is_a?(String) &&
  refresh.bytesize.between?(1, 16_384)
abort "expired refresh authority" unless
  Time.iso8601(session.fetch("refreshExpiresAt")) > Time.now
abort "missing public-user binding" unless session.dig("user", "id").is_a?(String)
File.write(ENV.fetch("REQUEST_FILE"), JSON.generate(refreshToken: refresh))
File.chmod(0o600, ENV.fetch("REQUEST_FILE"))
RUBY

http_code="$(curl -sS \
  --connect-timeout 15 \
  --max-time 60 \
  --output "${response_file}" \
  --write-out '%{http_code}' \
  --header 'content-type: application/json' \
  --data-binary "@${request_file}" \
  "${service_origin}/api/v2/auth/refresh")"
chmod 600 "${response_file}"
if [[ "${http_code}" != "200" ]]; then
  echo "ComiNavi rejected the protected refresh authority (${http_code}); the saved session was not replaced." >&2
  exit 1
fi

EXISTING_SESSION="${session_file}" RESPONSE_FILE="${response_file}" CURL_CONFIG="${curl_config}" ruby -rjson -rtime <<'RUBY'
existing = JSON.parse(File.read(ENV.fetch("EXISTING_SESSION")))
response = JSON.parse(File.read(ENV.fetch("RESPONSE_FILE")))
valid = response["tokenType"] == "Bearer" &&
  response.fetch("authVersion", 0).is_a?(Integer) && response.fetch("authVersion", 0).positive? &&
  response["accessToken"].is_a?(String) && !response["accessToken"].empty? &&
  response["refreshToken"].is_a?(String) && !response["refreshToken"].empty? &&
  Time.iso8601(response.fetch("expiresAt")) > Time.now &&
  Time.iso8601(response.fetch("refreshExpiresAt")) > Time.now &&
  response.dig("user", "id") == existing.dig("user", "id") &&
  response.dig("user", "id").to_s.match?(/\A[0-9a-f]{32}\z/) &&
  response.dig("user", "displayName").is_a?(String) && !response.dig("user", "displayName").empty? &&
  response.dig("user", "revision").is_a?(Integer) && response.dig("user", "revision").positive? &&
  response.dig("user", "identities").is_a?(Array)
abort "invalid refresh successor" unless valid
File.write(
  ENV.fetch("CURL_CONFIG"),
  "silent\nshow-error\nheader = \"authorization: Bearer #{response.fetch("accessToken")}\"\n",
)
File.chmod(0o600, ENV.fetch("CURL_CONFIG"))
RUBY

profile_code="$(curl --config "${curl_config}" \
  --retry 2 \
  --retry-connrefused \
  --connect-timeout 15 \
  --max-time 60 \
  --output "${profile_file}" \
  --write-out '%{http_code}' \
  "${service_origin}/api/v2/me")"
chmod 600 "${profile_file}"
if [[ "${profile_code}" != "200" ]]; then
  echo "The refreshed access token failed /api/v2/me validation (${profile_code}); the protected successor remains at ${response_file}." >&2
  exit 1
fi

RESPONSE_FILE="${response_file}" PROFILE_FILE="${profile_file}" ruby -rjson <<'RUBY'
response = JSON.parse(File.read(ENV.fetch("RESPONSE_FILE")))
profile = JSON.parse(File.read(ENV.fetch("PROFILE_FILE")))
profile_id = profile.fetch("id", nil)
valid_profile = profile_id.is_a?(String) && profile_id.match?(/\A[0-9a-f]{32}\z/) &&
  profile.fetch("displayName", "").is_a?(String) && !profile.fetch("displayName", "").empty? &&
  profile.fetch("revision", 0).is_a?(Integer) && profile.fetch("revision", 0).positive? &&
  profile.fetch("identities", nil).is_a?(Array)
abort "invalid profile response" unless valid_profile
abort "refresh/profile user mismatch" unless response.dig("user", "id") == profile_id
RUBY

mv -f "${response_file}" "${session_file}"

SESSION_FILE="${session_file}" ruby -rjson -e '
session = JSON.parse(File.read(ENV.fetch("SESSION_FILE")))
puts "Refreshed and validated the protected session for user #{session.dig("user", "id")}; access expires at #{session.fetch("expiresAt")}."
'
