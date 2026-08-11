#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
verify_script="$(cd "$script_dir/.." && pwd -P)/verify-openapi-contract-sync.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/cominavi-openapi-sync.XXXXXX")"

cleanup() {
  rm -rf -- "$fixture_root"
}
trap cleanup EXIT

server_contract="$fixture_root/server.json"
client_contract="$fixture_root/client.json"

printf '%s\n' '{"openapi":"3.1.1","paths":{}}' > "$server_contract"
cp "$server_contract" "$client_contract"

"$verify_script" "$server_contract" "$client_contract" >/dev/null

printf '%s\n' ' ' >> "$client_contract"
if "$verify_script" "$server_contract" "$client_contract" >/dev/null 2>&1; then
  echo "Expected byte-level contract drift to fail validation." >&2
  exit 1
fi

if "$verify_script" "$fixture_root/missing.json" "$client_contract" >/dev/null 2>&1; then
  echo "Expected a missing contract to fail validation." >&2
  exit 1
fi

echo "OpenAPI contract sync validation tests passed."
