#!/usr/bin/env bash
set -euo pipefail

POC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${POC_ROOT}/config.env}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck source=../config.env
source "${CONFIG_FILE}"

STATE_DIR="${POC_ROOT}/.state"
TOOLS_DIR="${POC_ROOT}/.tools"
KUBECONFIG_FILE="${STATE_DIR}/rke2.yaml"
MANIFESTS_DIR="${STATE_DIR}/kubeflow-manifests"

mkdir -p "${STATE_DIR}" "${TOOLS_DIR}"

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

vm_ip() {
  multipass info "$1" --format json |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(iter(d["info"].values()))["ipv4"][0])'
}

require_cluster() {
  [[ -f "${KUBECONFIG_FILE}" ]] || die "Run scripts/02-install-rke2.sh first."
  export KUBECONFIG="${KUBECONFIG_FILE}"
  kubectl get nodes >/dev/null
}

wait_for_node_ready() {
  local node="$1"
  kubectl wait --for=condition=Ready "node/${node}" --timeout=10m
}
