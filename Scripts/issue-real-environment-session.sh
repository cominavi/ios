#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
real_env_dir="${repo_root}/.real-env"
service_origin="${COMINAVI_E2E_SERVICE_ORIGIN:-https://cominavi.net}"
credentials_file="${COMINAVI_E2E_CREDENTIALS_FILE:-${repo_root}/credentials.yaml}"
browser_state="${COMINAVI_E2E_CIRCLEMS_BROWSER_STATE:-${real_env_dir}/circlems-browser-state.json}"
session_file="${COMINAVI_E2E_SERVICE_SESSION_FILE:-${real_env_dir}/laptop-issued-cominavi-service-session.json}"
browser_session="${COMINAVI_E2E_BROWSER_SESSION:-cominavi-circlems-session-issuer}"
browser_auth_profile="${COMINAVI_E2E_BROWSER_AUTH_PROFILE:-cominavi-circlems-e2e}"
temporary_directory="$(mktemp -d /tmp/cominavi-session-issuer.XXXXXX)"

cleanup() {
  find "${temporary_directory}" -type f -delete 2>/dev/null || true
  rmdir "${temporary_directory}" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${real_env_dir}"
chmod 700 "${real_env_dir}" "${temporary_directory}"

for command_name in agent-browser curl ruby; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    exit 1
  fi
done

case "${service_origin}" in
  https://cominavi.net) ;;
  *)
    echo "Refusing non-production ComiNavi service origin: ${service_origin}" >&2
    exit 1
    ;;
esac

run_browser() {
  AGENT_BROWSER_SESSION="${browser_session}" agent-browser "$@"
}

require_mode_600() {
  local path="$1"
  local mode
  mode="$(stat -f '%Lp' "${path}")"
  if [[ "${mode}" != "600" ]]; then
    echo "Refusing protected file with mode ${mode}; expected 600: ${path}" >&2
    exit 1
  fi
}

flow_private="${temporary_directory}/flow-private.json"
start_request="${temporary_directory}/start-request.json"
start_response="${temporary_directory}/start-response.json"
network_response="${temporary_directory}/network.json"
current_url_file="${temporary_directory}/current-url.txt"
callback_file="${temporary_directory}/callback.txt"
complete_request="${temporary_directory}/complete-request.json"
session_response="${temporary_directory}/session.json"
profile_response="${temporary_directory}/profile.json"
curl_config="${temporary_directory}/curl.conf"
username_file="${temporary_directory}/username.txt"
password_file="${temporary_directory}/password.txt"

ruby -ropenssl -rbase64 -rjson -rsecurerandom - "${flow_private}" "${start_request}" <<'RUBY'
def base64url(bytes)
  Base64.urlsafe_encode64(bytes, padding: false)
end

private_path, request_path = ARGV
verifier = base64url(OpenSSL::Random.random_bytes(32))
payload = {
  requestId: SecureRandom.uuid.downcase,
  clientInstanceID: SecureRandom.uuid.downcase,
  environment: "production",
  codeChallenge: base64url(OpenSSL::Digest::SHA256.digest(verifier)),
}
File.write(private_path, JSON.generate({ verifier: verifier, payload: payload }))
File.write(request_path, JSON.generate(payload))
File.chmod(0o600, private_path)
File.chmod(0o600, request_path)
RUBY

http_code="$(curl -sS \
  --output "${start_response}" \
  --write-out '%{http_code}' \
  --header 'content-type: application/json' \
  --data-binary "@${start_request}" \
  "${service_origin}/api/v2/auth/circlems/start")"
chmod 600 "${start_response}"
if [[ "${http_code}" != "200" ]]; then
  echo "ComiNavi rejected the Circle.ms OAuth start (${http_code})." >&2
  exit 1
fi

authorization_url="$(ruby -rjson -ruri -e '
  value = JSON.parse(File.read(ARGV.fetch(0))).fetch("authorizationURL")
  url = URI(value)
  abort "invalid authorization URL" unless url.scheme == "https" && url.host == "auth1.circle.ms" && !url.user && !url.password
  print value
' "${start_response}")"

run_browser network requests --clear >/dev/null
if [[ -f "${browser_state}" ]]; then
  require_mode_600 "${browser_state}"
  run_browser state load "${browser_state}" >/dev/null
fi
run_browser open "${authorization_url}" >/dev/null

capture_callback() {
  run_browser get url >"${current_url_file}" 2>/dev/null || true
  run_browser network requests --filter 'cominavi://' --json >"${network_response}" 2>/dev/null || true
  chmod 600 "${current_url_file}" "${network_response}"
  ruby -rjson -ruri - "${current_url_file}" "${network_response}" "${callback_file}" <<'RUBY'
current_path, network_path, callback_path = ARGV
urls = []
current = File.read(current_path).strip
urls << current if current.start_with?("cominavi://")
begin
  network = JSON.parse(File.read(network_path))
  walk = lambda do |value|
    case value
    when Hash
      value.each do |key, child|
        if key.to_s.downcase.include?("url") && child.is_a?(String) && child.start_with?("cominavi://")
          urls << child
        end
        walk.call(child)
      end
    when Array
      value.each { |child| walk.call(child) }
    end
  end
  walk.call(network)
rescue JSON::ParserError
end
exit 1 if urls.empty?

url = URI(urls.last)
values = URI.decode_www_form(url.query.to_s).to_h
valid = url.scheme == "cominavi" && url.host == "oauth" &&
  url.path == "/circlems/landing" && values["status"] == "succeeded" &&
  values.fetch("completionCode", "").match?(/\A[A-Za-z0-9_-]{43}\z/)
exit 1 unless valid
File.write(callback_path, urls.last)
File.chmod(0o600, callback_path)
RUBY
}

if ! run_browser wait '.btn-ninsho' --timeout 5000 >/dev/null 2>&1; then
  if ! capture_callback; then
    if [[ -n "${COMINAVI_CIRCLEMS_EMAIL:-}" && -n "${COMINAVI_CIRCLEMS_PASSWORD:-}" ]]; then
      EMAIL="${COMINAVI_CIRCLEMS_EMAIL}" PASSWORD="${COMINAVI_CIRCLEMS_PASSWORD}" \
        ruby -e 'File.write(ARGV[0], ENV.fetch("EMAIL")); File.write(ARGV[1], ENV.fetch("PASSWORD")); File.chmod(0600, ARGV[0]); File.chmod(0600, ARGV[1])' \
        "${username_file}" "${password_file}"
    else
      if [[ ! -f "${credentials_file}" ]]; then
        echo "The saved browser login expired and no credentials file exists." >&2
        exit 1
      fi
      require_mode_600 "${credentials_file}"
      CREDENTIALS_FILE="${credentials_file}" ruby -ryaml - "${username_file}" "${password_file}" <<'RUBY'
value = YAML.safe_load(File.read(ENV.fetch("CREDENTIALS_FILE")), permitted_classes: [], aliases: false)
circlems = value.fetch("circlems")
email = circlems.fetch("email")
password = circlems.fetch("password")
abort "invalid Circle.ms credentials" unless email.is_a?(String) && !email.empty? && password.is_a?(String) && !password.empty?
File.write(ARGV.fetch(0), email)
File.write(ARGV.fetch(1), password)
File.chmod(0o600, ARGV.fetch(0))
File.chmod(0o600, ARGV.fetch(1))
RUBY
    fi

    agent-browser auth save "${browser_auth_profile}" \
      --url "${authorization_url}" \
      --username "$(<"${username_file}")" \
      --password-stdin <"${password_file}" >/dev/null
    run_browser auth login "${browser_auth_profile}" --url "${authorization_url}" >/dev/null
    run_browser wait '.btn-ninsho' --timeout 15000 >/dev/null
  fi
fi

if [[ ! -f "${callback_file}" ]]; then
  run_browser click '.btn-ninsho' >/dev/null
  for _ in {1..20}; do
    if capture_callback; then
      break
    fi
    sleep 1
  done
fi
if [[ ! -f "${callback_file}" ]]; then
  echo "Circle.ms authorization did not return a ComiNavi completion code." >&2
  exit 1
fi

run_browser state save "${browser_state}" >/dev/null
chmod 600 "${browser_state}"

ruby -rjson -ruri - "${flow_private}" "${callback_file}" "${complete_request}" <<'RUBY'
private_data = JSON.parse(File.read(ARGV.fetch(0)))
callback = URI(File.read(ARGV.fetch(1)).strip)
completion_code = URI.decode_www_form(callback.query.to_s).to_h.fetch("completionCode")
payload = private_data.fetch("payload")
request = {
  requestId: payload.fetch("requestId"),
  clientInstanceID: payload.fetch("clientInstanceID"),
  completionCode: completion_code,
  codeVerifier: private_data.fetch("verifier"),
}
File.write(ARGV.fetch(2), JSON.generate(request))
File.chmod(0o600, ARGV.fetch(2))
RUBY

http_code="$(curl -sS \
  --output "${session_response}" \
  --write-out '%{http_code}' \
  --header 'content-type: application/json' \
  --data-binary "@${complete_request}" \
  "${service_origin}/api/v2/auth/circlems/complete")"
chmod 600 "${session_response}"
if [[ "${http_code}" != "200" ]]; then
  echo "ComiNavi rejected the Circle.ms OAuth completion (${http_code})." >&2
  exit 1
fi

ruby -rjson -rtime - "${session_response}" "${curl_config}" "${complete_request}" <<'RUBY'
session = JSON.parse(File.read(ARGV.fetch(0)))
completion = JSON.parse(File.read(ARGV.fetch(2)))
valid = session["tokenType"] == "Bearer" &&
  session.fetch("authVersion", 0).is_a?(Integer) && session.fetch("authVersion", 0).positive? &&
  session.fetch("accessToken", "").is_a?(String) && !session.fetch("accessToken", "").empty? &&
  Time.iso8601(session.fetch("expiresAt")) > Time.now &&
  session.fetch("refreshToken", "").is_a?(String) && !session.fetch("refreshToken", "").empty? &&
  Time.iso8601(session.fetch("refreshExpiresAt")) > Time.now &&
  session.dig("user", "id").to_s.match?(/\A[0-9a-f]{32}\z/) &&
  session.dig("user", "displayName").is_a?(String) && !session.dig("user", "displayName").empty? &&
  session.dig("user", "revision").is_a?(Integer) && session.dig("user", "revision").positive? &&
  session.dig("user", "identities").is_a?(Array) &&
  session.dig("credentialReceipt", "requestId") == completion.fetch("requestId") &&
  session.dig("credentialReceipt", "clientInstanceID") == completion.fetch("clientInstanceID") &&
  session.dig("credentialReceipt", "provider") == "circlems" &&
  session.dig("credentialReceipt", "environment") == "production" &&
  session.dig("credentialReceipt", "subject").is_a?(String) && !session.dig("credentialReceipt", "subject").empty? &&
  session.dig("credentialReceipt", "credentialRevision").is_a?(Integer) &&
  session.dig("credentialReceipt", "credentialRevision").positive?
abort "invalid ComiNavi session response" unless valid
File.write(ARGV.fetch(1), "silent\nshow-error\nheader = \"authorization: Bearer #{session.fetch("accessToken")}\"\n")
File.chmod(0o600, ARGV.fetch(1))
RUBY

http_code="$(curl --config "${curl_config}" \
  --output "${profile_response}" \
  --write-out '%{http_code}' \
  "${service_origin}/api/v2/me")"
chmod 600 "${profile_response}"
if [[ "${http_code}" != "200" ]]; then
  echo "The issued ComiNavi access token failed its /me validation (${http_code})." >&2
  exit 1
fi
ruby -rjson -e '
  session = JSON.parse(File.read(ARGV.fetch(0)))
  profile = JSON.parse(File.read(ARGV.fetch(1)))
  profile_id = profile.fetch("id", nil)
  valid_profile = profile_id.is_a?(String) && profile_id.match?(/\A[0-9a-f]{32}\z/) &&
    profile.fetch("displayName", "").is_a?(String) && !profile.fetch("displayName", "").empty? &&
    profile.fetch("revision", 0).is_a?(Integer) && profile.fetch("revision", 0).positive? &&
    profile.fetch("identities", nil).is_a?(Array)
  abort "invalid profile response" unless valid_profile
  abort "session/profile user mismatch" unless session.dig("user", "id") == profile_id
' "${session_response}" "${profile_response}"

mkdir -p "$(dirname "${session_file}")"
install -m 600 "${session_response}" "${session_file}.new"
mv -f "${session_file}.new" "${session_file}"

echo "Issued and validated a production ComiNavi session at ${session_file}."
echo "The Circle.ms browser login remains saved at ${browser_state}."

if [[ "${COMINAVI_E2E_INSTALL_SESSION:-0}" == "1" ]]; then
  COMINAVI_E2E_SERVICE_SESSION_FILE="${session_file}" \
  COMINAVI_E2E_REPLACE_EXISTING_SERVICE_SESSION="${COMINAVI_E2E_REPLACE_EXISTING_SERVICE_SESSION:-1}" \
  "${script_dir}/bootstrap-real-environment-session.sh"
fi
