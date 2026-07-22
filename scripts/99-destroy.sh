#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command multipass

if [[ "${1:-}" != "--yes" ]]; then
  cat >&2 <<EOF
This permanently deletes:
  - ${SERVER_VM}
  - ${AGENT_VM}
  - ${STATE_DIR}

Run again with --yes to confirm.
EOF
  exit 1
fi

for vm in "${SERVER_VM}" "${AGENT_VM}"; do
  if multipass info "${vm}" >/dev/null 2>&1; then
    multipass delete --purge "${vm}"
  fi
done

rm -rf "${STATE_DIR}" "${TOOLS_DIR}"
echo "POC cluster and generated state removed."
