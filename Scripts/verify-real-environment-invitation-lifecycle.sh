#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# First prove the active capability through cold universal-link and warm
# custom-scheme presentation. Only then revoke it and create literal expiry
# evidence; terminal preparation leaves another active capability in place.
"${script_dir}/verify-real-environment-invitation-web.sh"
"${script_dir}/verify-real-environment-invitation-ui.sh"
"${script_dir}/prepare-real-environment-invitation-terminal-states.sh"
COMINAVI_E2E_VERIFY_TERMINAL_INVITATIONS=1 \
  "${script_dir}/verify-real-environment-invitation-ui.sh"

echo "Production invitation active, reusable/already-member, revoked, and expired lifecycle acceptance passed."
