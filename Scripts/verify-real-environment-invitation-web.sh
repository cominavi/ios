#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
real_env_dir="${repo_root}/.real-env"
invitation_file="${COMINAVI_E2E_INVITATION_FILE:-${real_env_dir}/shared-plan-invitation.json}"
expected_plan_name="${COMINAVI_E2E_INVITATION_PLAN_NAME:-[E2E] Shared Plan Lifecycle v1}"
run_directory="$(mktemp -d /tmp/cominavi-invitation-web.XXXXXX)"
headers_file="${run_directory}/headers.txt"
body_file="${run_directory}/body.html"

umask 077
chmod 700 "${run_directory}"
touch "${headers_file}" "${body_file}"
chmod 600 "${headers_file}" "${body_file}"

cleanup() {
  find "${run_directory}" -type f -delete 2>/dev/null || true
  rmdir "${run_directory}" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -f "${invitation_file}" ]]; then
  echo "Missing protected invitation: ${invitation_file}" >&2
  exit 1
fi
mode="$(stat -f '%Lp' "${invitation_file}")"
if [[ "${mode}" != "600" ]]; then
  echo "Refusing invitation file with mode ${mode}; expected 600." >&2
  exit 1
fi

before_hash="$(shasum -a 256 "${invitation_file}" | cut -d ' ' -f 1)"
canonical_url="$(INVITATION_FILE="${invitation_file}" ruby -rjson -ruri -e '
  invitation = JSON.parse(File.read(ENV.fetch("INVITATION_FILE")))
  token = invitation.fetch("token")
  abort "invalid invitation token" unless token.match?(/\A[A-Za-z0-9_-]{12}\z/)
  url = URI.parse(invitation.fetch("canonicalURL"))
  abort "invalid canonical URL" unless url.scheme == "https" && url.host == "cominavi.net" && url.path == "/join/#{token}"
  print url
')"

http_status="$(curl \
  --silent \
  --show-error \
  --location \
  --max-redirs 0 \
  --dump-header "${headers_file}" \
  --output "${body_file}" \
  --write-out '%{http_code}' \
  "${canonical_url}")"
if [[ "${http_status}" != "200" ]]; then
  echo "The production invitation page returned HTTP ${http_status}." >&2
  exit 1
fi

HEADERS_FILE="${headers_file}" BODY_FILE="${body_file}" EXPECTED_PLAN_NAME="${expected_plan_name}" CANONICAL_URL="${canonical_url}" ruby -ruri <<'RUBY'
headers = File.read(ENV.fetch("HEADERS_FILE"))
body = File.read(ENV.fetch("BODY_FILE"))
normalized = headers.downcase
abort "missing no-store" unless normalized.match?(/^cache-control:\s*[^\r\n]*no-store/im)
abort "missing no-referrer" unless normalized.match?(/^referrer-policy:\s*no-referrer\s*$/im)
abort "missing no-index" unless normalized.match?(/^x-robots-tag:\s*[^\r\n]*noindex/im)

url = URI.parse(ENV.fetch("CANONICAL_URL"))
token = url.path.split("/").last
required = [
  ENV.fetch("EXPECTED_PLAN_NAME"),
  "COMIKET 108",
  "ComiNavi で開く",
  "App Store で入手",
  "このページは特定の受取人を示すものではありません",
  "cominavi://join/#{token}",
]
required.each { |value| abort "missing expected invitation content" unless body.include?(value) }
abort "active capability rendered unavailable" if body.include?("この招待は利用できません")
RUBY

after_hash="$(shasum -a 256 "${invitation_file}" | cut -d ' ' -f 1)"
if [[ "${before_hash}" != "${after_hash}" ]]; then
  echo "The read-only web verification changed the protected invitation file." >&2
  exit 1
fi

echo "Production invitation web fallback, privacy, and cache-safety acceptance passed."
