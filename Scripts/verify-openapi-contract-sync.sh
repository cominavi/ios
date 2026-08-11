#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ios_root="$(cd "$script_dir/.." && pwd -P)"
workspace_root="$(cd "$ios_root/.." && pwd -P)"

server_contract="${1:-$workspace_root/homepage/openapi/cominavi-openapi.json}"
client_contract="${2:-$ios_root/Packages/CominaviAPIClient/Sources/CominaviAPIClient/openapi.json}"

if [[ $# -gt 2 ]]; then
  echo "Usage: $0 [server-contract client-contract]" >&2
  exit 64
fi

if [[ ! -f "$server_contract" ]]; then
  echo "Server OpenAPI contract not found: $server_contract" >&2
  exit 66
fi

if [[ ! -f "$client_contract" ]]; then
  echo "iOS OpenAPI contract not found: $client_contract" >&2
  exit 66
fi

if ! cmp -s "$server_contract" "$client_contract"; then
  echo "OpenAPI contract drift detected." >&2
  echo "Server contract: $server_contract" >&2
  echo "iOS contract:    $client_contract" >&2
  echo "Regenerate the server contract, then copy it byte-for-byte into the iOS client package." >&2
  exit 1
fi

echo "OpenAPI contracts are byte-for-byte identical."
