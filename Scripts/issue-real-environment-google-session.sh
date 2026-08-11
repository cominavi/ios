#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
real_env_dir="${repo_root}/.real-env"
service_origin="${COMINAVI_E2E_SERVICE_ORIGIN:-https://cominavi.net}"
invitation_file="${COMINAVI_E2E_INVITATION_FILE:-${real_env_dir}/shared-plan-invitation.json}"
browser_state="${COMINAVI_E2E_GOOGLE_BROWSER_STATE:-${real_env_dir}/google-browser-state.json}"
browser_profile="${COMINAVI_E2E_GOOGLE_BROWSER_PROFILE:-${real_env_dir}/google-chrome-profile}"
session_file="${COMINAVI_E2E_SERVICE_SESSION_FILE:-${real_env_dir}/google-recipient-service-session.json}"
browser_session="${COMINAVI_E2E_BROWSER_SESSION:-cominavi-google-session-issuer}"
external_handoff_dir="${COMINAVI_E2E_EXTERNAL_BROWSER_HANDOFF_DIR:-}"
google_client_id="${COMINAVI_E2E_GOOGLE_CLIENT_ID:-90593751186-1pj9cb56nuasbvn31lah71kl1ljmfvj2.apps.googleusercontent.com}"
google_callback_scheme="${COMINAVI_E2E_GOOGLE_CALLBACK_SCHEME:-com.googleusercontent.apps.90593751186-1pj9cb56nuasbvn31lah71kl1ljmfvj2}"
google_redirect_uri="${google_callback_scheme}:/oauth2callback"
temporary_directory="$(mktemp -d /tmp/cominavi-google-session-issuer.XXXXXX)"
chrome_pid=""
external_authorization_file=""
external_callback_file=""

cleanup() {
  if [[ -n "${chrome_pid}" ]]; then
    kill "${chrome_pid}" 2>/dev/null || true
    wait "${chrome_pid}" 2>/dev/null || true
  fi
  [[ -z "${external_authorization_file}" ]] || find "${external_authorization_file}" -maxdepth 0 -type f -delete 2>/dev/null || true
  [[ -z "${external_callback_file}" ]] || find "${external_callback_file}" -maxdepth 0 -type f -delete 2>/dev/null || true
  find "${temporary_directory}" -type f -delete 2>/dev/null || true
  rmdir "${temporary_directory}" 2>/dev/null || true
}
trap cleanup EXIT

umask 077
mkdir -p "${real_env_dir}" "${browser_profile}"
chmod 700 "${real_env_dir}" "${browser_profile}" "${temporary_directory}"

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

if [[ ! -f "${invitation_file}" ]]; then
  echo "Missing protected Shared Plan invitation: ${invitation_file}" >&2
  exit 1
fi

require_mode_600() {
  local path="$1"
  local mode
  mode="$(stat -f '%Lp' "${path}")"
  if [[ "${mode}" != "600" ]]; then
    echo "Refusing protected file with mode ${mode}; expected 600: ${path}" >&2
    exit 1
  fi
}

require_mode_600 "${invitation_file}"

case "${google_client_id}" in
  *.apps.googleusercontent.com) ;;
  *)
    echo "Refusing malformed Google iOS client ID." >&2
    exit 1
    ;;
esac
if [[ "${google_callback_scheme}" != "com.googleusercontent.apps.${google_client_id%.apps.googleusercontent.com}" ]]; then
  echo "Google callback scheme does not match the configured iOS client ID." >&2
  exit 1
fi

run_browser() {
  AGENT_BROWSER_SESSION="${browser_session}" agent-browser "$@"
}

flow_private="${temporary_directory}/flow-private.json"
authorization_url_file="${temporary_directory}/authorization-url.txt"
current_url_file="${temporary_directory}/current-url.txt"
network_response="${temporary_directory}/network.json"
callback_file="${temporary_directory}/callback.txt"
token_form="${temporary_directory}/token-form.txt"
google_token_response="${temporary_directory}/google-token.json"
entry_request="${temporary_directory}/entry-request.json"
entry_response="${temporary_directory}/entry-response.json"
auth_request="${temporary_directory}/auth-request.json"
session_response="${temporary_directory}/session.json"
profile_response="${temporary_directory}/profile.json"
curl_config="${temporary_directory}/curl.conf"
chrome_log="${temporary_directory}/chrome.log"

GOOGLE_CLIENT_ID="${google_client_id}" \
GOOGLE_REDIRECT_URI="${google_redirect_uri}" \
GOOGLE_PROMPT="${COMINAVI_E2E_GOOGLE_PROMPT:-}" \
ruby -ropenssl -rbase64 -rjson -rsecurerandom -rtime -ruri - \
  "${invitation_file}" "${flow_private}" "${authorization_url_file}" <<'RUBY'
def base64url(bytes)
  Base64.urlsafe_encode64(bytes, padding: false)
end

invitation_path, private_path, authorization_path = ARGV
invitation = JSON.parse(File.read(invitation_path))
invite_url = URI(invitation.fetch("canonicalURL"))
abort "invalid invitation URL" unless invite_url.scheme == "https" &&
  invite_url.host == "cominavi.net" && invite_url.query.nil? && invite_url.fragment.nil?
match = invite_url.path.match(%r{\A/join/([A-Za-z0-9]{12})\z})
abort "invalid invitation token" unless match && invitation["token"] == match[1]
encoded_expiry = invitation.fetch("expiresAt")
expiry = if encoded_expiry.is_a?(Numeric)
  Time.at(encoded_expiry + 978_307_200)
else
  Time.iso8601(encoded_expiry)
end
abort "expired invitation" unless expiry > Time.now

verifier = base64url(OpenSSL::Random.random_bytes(32))
nonce = base64url(OpenSSL::Random.random_bytes(32))
state = base64url(OpenSSL::Random.random_bytes(32))
private_data = {
  verifier: verifier,
  nonce: nonce,
  state: state,
  requestId: SecureRandom.uuid.downcase,
  inviteToken: match[1],
}
authorization = URI("https://accounts.google.com/o/oauth2/v2/auth")
authorization_parameters = {
  client_id: ENV.fetch("GOOGLE_CLIENT_ID"),
  redirect_uri: ENV.fetch("GOOGLE_REDIRECT_URI"),
  response_type: "code",
  scope: "openid email profile",
  nonce: nonce,
  state: state,
  code_challenge: base64url(OpenSSL::Digest::SHA256.digest(verifier)),
  code_challenge_method: "S256",
  include_granted_scopes: "true",
}
prompt = ENV.fetch("GOOGLE_PROMPT")
authorization_parameters[:prompt] = prompt unless prompt.empty?
authorization.query = URI.encode_www_form(authorization_parameters)
File.write(private_path, JSON.generate(private_data))
File.write(authorization_path, authorization.to_s)
File.chmod(0o600, private_path)
File.chmod(0o600, authorization_path)
RUBY

authorization_url="$(<"${authorization_url_file}")"
if [[ -n "${external_handoff_dir}" ]]; then
  case "${external_handoff_dir}" in
    "${real_env_dir}"/*) ;;
    *)
      echo "External browser handoff must stay inside ${real_env_dir}." >&2
      exit 1
      ;;
  esac
  mkdir -p "${external_handoff_dir}"
  chmod 700 "${external_handoff_dir}"
  external_authorization_file="${external_handoff_dir}/authorization-url.txt"
  external_callback_file="${external_handoff_dir}/callback-url.txt"
  rejected_callback_directory="${external_handoff_dir}/rejected-callbacks/flow-$$"
  mkdir -p "${rejected_callback_directory}"
  chmod 700 "${rejected_callback_directory}"
  install -m 600 "${authorization_url_file}" "${external_authorization_file}"
  find "${external_callback_file}" -maxdepth 0 -type f -delete 2>/dev/null || true

  echo "Waiting for the already-authenticated external browser to complete Google authorization."
  rejected_callback_count=0
  for _ in {1..600}; do
    if [[ -f "${external_callback_file}" ]]; then
      install -m 600 "${external_callback_file}" "${callback_file}"
      if CALLBACK_SCHEME="${google_callback_scheme}" ruby -rjson -ruri - \
        "${flow_private}" "${callback_file}" <<'RUBY'
private_data = JSON.parse(File.read(ARGV.fetch(0)))
callback = URI(File.read(ARGV.fetch(1)).strip)
values = URI.decode_www_form(callback.query.to_s).to_h
matches_flow = callback.scheme == ENV.fetch("CALLBACK_SCHEME") &&
  callback.path == "/oauth2callback" &&
  values["state"] == private_data.fetch("state")
exit 1 unless matches_flow
exit 2 unless values["error"].nil? &&
  values.fetch("code", "").bytesize.between?(16, 4096)
exit 0
RUBY
      then
        break
      else
        callback_validation_status=$?
      fi

      if (( callback_validation_status == 2 )); then
        provider_error_file="${rejected_callback_directory}/provider-error.txt"
        install -m 600 "${external_callback_file}" "${provider_error_file}"
        provider_error="$(ruby -ruri -e '
          callback = URI(File.read(ARGV.fetch(0)).strip)
          values = URI.decode_www_form(callback.query.to_s).to_h
          error = values["error"].to_s
          puts(error.match?(/\A[a-z0-9_]+\z/) ? error : "invalid_callback")
        ' "${provider_error_file}")"
        echo "Google returned ${provider_error} for the current authorization request; no token exchange occurred." >&2
        exit 1
      fi

      rejected_callback_count=$((rejected_callback_count + 1))
      if (( rejected_callback_count > 16 )); then
        echo "Too many non-matching external Google callbacks; refusing to continue." >&2
        exit 1
      fi
      rejected_callback_file="${rejected_callback_directory}/callback-${rejected_callback_count}.txt"
      install -m 600 "${external_callback_file}" "${rejected_callback_file}"
      find "${external_callback_file}" -maxdepth 0 -type f -delete
      find "${callback_file}" -maxdepth 0 -type f -delete
      echo "Preserved a callback that did not match the current authorization state; still waiting."
    fi
    sleep 1
  done
  if [[ ! -f "${callback_file}" ]]; then
    echo "External Google authorization did not return a callback within ten minutes." >&2
    exit 1
  fi

  CALLBACK_SCHEME="${google_callback_scheme}" ruby -rjson -ruri - \
    "${flow_private}" "${callback_file}" <<'RUBY'
private_data = JSON.parse(File.read(ARGV.fetch(0)))
callback = URI(File.read(ARGV.fetch(1)).strip)
values = URI.decode_www_form(callback.query.to_s).to_h
valid = callback.scheme == ENV.fetch("CALLBACK_SCHEME") &&
  callback.path == "/oauth2callback" &&
  values["state"] == private_data.fetch("state") &&
  values.fetch("code", "").bytesize.between?(16, 4096) &&
  values["error"].nil?
abort "invalid external Google callback" unless valid
RUBY
else
chrome_executable="${COMINAVI_E2E_CHROME_EXECUTABLE:-}"
if [[ -z "${chrome_executable}" ]]; then
  chrome_executable="$(find "${HOME}/.agent-browser/browsers" -path '*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing' -type f -print 2>/dev/null | sort | tail -1)"
fi
if [[ -z "${chrome_executable}" || ! -x "${chrome_executable}" ]]; then
  echo "Missing Google Chrome for Testing; run 'agent-browser install' first." >&2
  exit 1
fi

remote_debugging_port="$(ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); puts server.addr.fetch(1); server.close')"
"${chrome_executable}" \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port="${remote_debugging_port}" \
  --user-data-dir="${browser_profile}" \
  --no-first-run \
  --no-default-browser-check \
  about:blank >"${chrome_log}" 2>&1 &
chrome_pid="$!"

for _ in {1..100}; do
  if curl -fsS "http://127.0.0.1:${remote_debugging_port}/json/version" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if ! curl -fsS "http://127.0.0.1:${remote_debugging_port}/json/version" >/dev/null 2>&1; then
  echo "The isolated visible Google browser did not start." >&2
  exit 1
fi

run_browser close >/dev/null 2>&1 || true
run_browser connect "${remote_debugging_port}" >/dev/null
run_browser network requests --clear >/dev/null
if [[ -f "${browser_state}" ]]; then
  require_mode_600 "${browser_state}"
  run_browser state load "${browser_state}" >/dev/null
fi
run_browser open "${authorization_url}" >/dev/null

echo "Complete Google sign-in in the opened browser if it asks for consent."
echo "The script will continue automatically after Google returns the authorization code."

capture_callback() {
  run_browser get url >"${current_url_file}" 2>/dev/null || true
  run_browser network requests --filter "${google_callback_scheme}:" --json >"${network_response}" 2>/dev/null || true
  chmod 600 "${current_url_file}" "${network_response}"
  CALLBACK_SCHEME="${google_callback_scheme}" ruby -rjson -ruri - \
    "${flow_private}" "${current_url_file}" "${network_response}" "${callback_file}" <<'RUBY'
private_path, current_path, network_path, callback_path = ARGV
urls = []
current = File.read(current_path).strip
urls << current if current.start_with?("#{ENV.fetch("CALLBACK_SCHEME")}:")
begin
  network = JSON.parse(File.read(network_path))
  walk = lambda do |value|
    case value
    when Hash
      value.each do |key, child|
        if key.to_s.downcase.include?("url") && child.is_a?(String) &&
            child.start_with?("#{ENV.fetch("CALLBACK_SCHEME")}:")
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

private_data = JSON.parse(File.read(private_path))
callback = URI(urls.last)
values = URI.decode_www_form(callback.query.to_s).to_h
valid = callback.scheme == ENV.fetch("CALLBACK_SCHEME") &&
  callback.path == "/oauth2callback" &&
  values["state"] == private_data.fetch("state") &&
  values.fetch("code", "").bytesize.between?(16, 4096) &&
  values["error"].nil?
exit 1 unless valid
File.write(callback_path, urls.last)
File.chmod(0o600, callback_path)
RUBY
}

for _ in {1..600}; do
  if capture_callback; then
    break
  fi
  sleep 1
done
if [[ ! -f "${callback_file}" ]]; then
  echo "Google authorization did not return a valid callback within ten minutes." >&2
  exit 1
fi

run_browser state save "${browser_state}" >/dev/null
chmod 600 "${browser_state}"
fi

GOOGLE_CLIENT_ID="${google_client_id}" \
GOOGLE_REDIRECT_URI="${google_redirect_uri}" \
ruby -rjson -ruri - "${flow_private}" "${callback_file}" "${token_form}" <<'RUBY'
private_data = JSON.parse(File.read(ARGV.fetch(0)))
callback = URI(File.read(ARGV.fetch(1)).strip)
code = URI.decode_www_form(callback.query.to_s).to_h.fetch("code")
form = URI.encode_www_form(
  client_id: ENV.fetch("GOOGLE_CLIENT_ID"),
  code: code,
  code_verifier: private_data.fetch("verifier"),
  redirect_uri: ENV.fetch("GOOGLE_REDIRECT_URI"),
  grant_type: "authorization_code",
)
File.write(ARGV.fetch(2), form)
File.chmod(0o600, ARGV.fetch(2))
RUBY

http_code="$(curl -sS \
  --output "${google_token_response}" \
  --write-out '%{http_code}' \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data-binary "@${token_form}" \
  'https://oauth2.googleapis.com/token')"
chmod 600 "${google_token_response}"
if [[ "${http_code}" != "200" ]]; then
  echo "Google rejected the PKCE authorization-code exchange (${http_code})." >&2
  exit 1
fi

GOOGLE_CLIENT_ID="${google_client_id}" ruby -rbase64 -rjson - \
  "${flow_private}" "${google_token_response}" "${entry_request}" <<'RUBY'
private_data = JSON.parse(File.read(ARGV.fetch(0)))
tokens = JSON.parse(File.read(ARGV.fetch(1)))
id_token = tokens.fetch("id_token")
parts = id_token.split(".", -1)
abort "invalid Google identity token" unless parts.length == 3
payload = parts.fetch(1).tr("-_", "+/")
payload += "=" * ((4 - payload.length % 4) % 4)
claims = JSON.parse(Base64.strict_decode64(payload))
audiences = claims["aud"].is_a?(Array) ? claims["aud"] : [claims["aud"]]
valid = audiences.include?(ENV.fetch("GOOGLE_CLIENT_ID")) &&
  claims["nonce"] == private_data.fetch("nonce") &&
  Integer(claims.fetch("exp")) > Time.now.to_i
abort "Google identity-token claims do not match this flow" unless valid
request = {
  nonce: private_data.fetch("nonce"),
  inviteToken: private_data.fetch("inviteToken"),
}
File.write(ARGV.fetch(2), JSON.generate(request))
File.chmod(0o600, ARGV.fetch(2))
RUBY

http_code="$(curl -sS \
  --output "${entry_response}" \
  --write-out '%{http_code}' \
  --header 'content-type: application/json' \
  --data-binary "@${entry_request}" \
  "${service_origin}/api/v2/auth/google/entry-grant")"
chmod 600 "${entry_response}"
if [[ "${http_code}" != "200" ]]; then
  echo "ComiNavi rejected the invitation-bound Google entry grant (${http_code})." >&2
  exit 1
fi

ruby -rjson -rtime - "${flow_private}" "${google_token_response}" "${entry_response}" "${auth_request}" <<'RUBY'
private_data = JSON.parse(File.read(ARGV.fetch(0)))
tokens = JSON.parse(File.read(ARGV.fetch(1)))
entry = JSON.parse(File.read(ARGV.fetch(2)))
abort "invalid ComiNavi entry grant" unless entry.fetch("entryGrant", "").is_a?(String) &&
  entry.fetch("entryGrant", "").bytesize.between?(1, 16_384) &&
  Time.iso8601(entry.fetch("expiresAt")) > Time.now
request = {
  requestId: private_data.fetch("requestId"),
  idToken: tokens.fetch("id_token"),
  entryGrant: entry.fetch("entryGrant"),
  nonce: private_data.fetch("nonce"),
}
File.write(ARGV.fetch(3), JSON.generate(request))
File.chmod(0o600, ARGV.fetch(3))
RUBY

http_code="$(curl -sS \
  --output "${session_response}" \
  --write-out '%{http_code}' \
  --header 'content-type: application/json' \
  --data-binary "@${auth_request}" \
  "${service_origin}/api/v2/auth/google")"
chmod 600 "${session_response}"
if [[ "${http_code}" != "200" ]]; then
  echo "ComiNavi rejected the Google authentication result (${http_code})." >&2
  exit 1
fi

ruby -rjson -rtime - "${session_response}" "${curl_config}" <<'RUBY'
session = JSON.parse(File.read(ARGV.fetch(0)))
valid = session["tokenType"] == "Bearer" &&
  session.fetch("authVersion", 0).is_a?(Integer) && session.fetch("authVersion", 0).positive? &&
  session.fetch("accessToken", "").is_a?(String) && !session.fetch("accessToken", "").empty? &&
  Time.iso8601(session.fetch("expiresAt")) > Time.now &&
  session.fetch("refreshToken", "").is_a?(String) && !session.fetch("refreshToken", "").empty? &&
  Time.iso8601(session.fetch("refreshExpiresAt")) > Time.now &&
  session.dig("user", "id").to_s.match?(/\A[0-9a-f]{32}\z/) &&
  session.dig("user", "displayName").is_a?(String) && !session.dig("user", "displayName").empty? &&
  session.dig("user", "revision").is_a?(Integer) && session.dig("user", "revision").positive? &&
  session.dig("user", "identities").is_a?(Array)
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

echo "Issued and validated a production Google-backed ComiNavi session at ${session_file}."
echo "The Google browser login remains saved at ${browser_state}."

if [[ "${COMINAVI_E2E_INSTALL_SESSION:-0}" == "1" ]]; then
  if [[ -n "${COMINAVI_TEST_DESTINATION:-}" ]]; then
    destination="${COMINAVI_TEST_DESTINATION}"
  else
    simulator_record="${real_env_dir}/recipient-simulator-udid.txt"
    if [[ ! -f "${simulator_record}" ]]; then
      echo "Missing recipient Simulator record: ${simulator_record}" >&2
      exit 1
    fi
    require_mode_600 "${simulator_record}"
    destination="platform=iOS Simulator,id=$(<"${simulator_record}")"
  fi
  COMINAVI_E2E_SERVICE_SESSION_FILE="${session_file}" \
  COMINAVI_E2E_REPLACE_EXISTING_SERVICE_SESSION="${COMINAVI_E2E_REPLACE_EXISTING_SERVICE_SESSION:-1}" \
  COMINAVI_TEST_DESTINATION="${destination}" \
  "${script_dir}/bootstrap-real-environment-session.sh"
fi
