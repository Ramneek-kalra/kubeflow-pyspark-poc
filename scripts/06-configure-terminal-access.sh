#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command kubectl
[[ -f "${KUBECONFIG_FILE}" ]] || die "Run scripts/02-install-rke2.sh first."

CONTEXT_NAME="poc-kubeflow-rke2"
USER_CONFIG="${HOME}/.kube/config"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

mkdir -p "${HOME}/.kube"

# Convert the RKE2 generic default names into collision-safe names before
# merging them with any kubeconfigs the user already has.
kubectl config view --raw --flatten \
  --kubeconfig "${KUBECONFIG_FILE}" -o json >"${tmp_dir}/poc.json"

python3 - "${tmp_dir}/poc.json" "${CONTEXT_NAME}" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
name = sys.argv[2]
config = json.loads(path.read_text())

config["clusters"][0]["name"] = name
config["users"][0]["name"] = name
config["contexts"][0]["name"] = name
config["contexts"][0]["context"]["cluster"] = name
config["contexts"][0]["context"]["user"] = name
config["current-context"] = name

path.write_text(json.dumps(config))
PY

if [[ -s "${USER_CONFIG}" ]]; then
  cp "${USER_CONFIG}" "${USER_CONFIG}.backup-$(date +%Y%m%d-%H%M%S)"
  cp "${USER_CONFIG}" "${tmp_dir}/existing"

  # Make reruns idempotent.
  kubectl --kubeconfig "${tmp_dir}/existing" config delete-context "${CONTEXT_NAME}" >/dev/null 2>&1 || true
  kubectl --kubeconfig "${tmp_dir}/existing" config delete-cluster "${CONTEXT_NAME}" >/dev/null 2>&1 || true
  kubectl --kubeconfig "${tmp_dir}/existing" config unset "users.${CONTEXT_NAME}" >/dev/null 2>&1 || true

  KUBECONFIG="${tmp_dir}/existing:${tmp_dir}/poc.json" \
    kubectl config view --raw --flatten >"${tmp_dir}/merged"
else
  cp "${tmp_dir}/poc.json" "${tmp_dir}/merged"
fi

mv "${tmp_dir}/merged" "${USER_CONFIG}"
chmod 600 "${USER_CONFIG}"
kubectl --kubeconfig "${USER_CONFIG}" config use-context "${CONTEXT_NAME}" >/dev/null

echo "Terminal Kubernetes access configured."
kubectl --kubeconfig "${USER_CONFIG}" config get-contexts
kubectl --kubeconfig "${USER_CONFIG}" get nodes
