#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command multipass

if [[ "${STOP_OLD_LAB_VMS:-false}" == "true" ]]; then
  log "Stopping old lab VMs to free host memory"
  for vm in rke2-server rke2-agent-1 rke2-agent-2; do
    if multipass info "${vm}" >/dev/null 2>&1; then
      multipass stop "${vm}" || true
    fi
  done
fi

create_vm() {
  local name="$1" cpus="$2" memory="$3" disk="$4"
  if multipass info "${name}" >/dev/null 2>&1; then
    echo "${name} already exists; skipping."
    return
  fi

  log "Creating ${name} (${cpus} CPU, ${memory} RAM, ${disk} disk)"
  multipass launch "${UBUNTU_IMAGE}" \
    --name "${name}" \
    --cpus "${cpus}" \
    --memory "${memory}" \
    --disk "${disk}"
}

create_vm "${SERVER_VM}" "${SERVER_CPUS}" "${SERVER_MEMORY}" "${SERVER_DISK}"
create_vm "${AGENT_VM}" "${AGENT_CPUS}" "${AGENT_MEMORY}" "${AGENT_DISK}"

log "POC virtual machines"
multipass list | awk 'NR == 1 || /poc-kf-rke2/'

cat <<EOF

Next:
  ${POC_ROOT}/scripts/02-install-rke2.sh
EOF
