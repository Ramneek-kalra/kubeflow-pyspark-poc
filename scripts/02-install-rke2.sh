#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command multipass
require_command kubectl
require_command openssl

multipass info "${SERVER_VM}" >/dev/null 2>&1 || die "Run scripts/01-create-vms.sh first."
multipass info "${AGENT_VM}" >/dev/null 2>&1 || die "Run scripts/01-create-vms.sh first."

multipass start "${SERVER_VM}" "${AGENT_VM}" >/dev/null 2>&1 || true
SERVER_IP="$(vm_ip "${SERVER_VM}")"
AGENT_IP="$(vm_ip "${AGENT_VM}")"
TOKEN_FILE="${STATE_DIR}/rke2-token"

if [[ ! -s "${TOKEN_FILE}" ]]; then
  umask 077
  openssl rand -hex 32 >"${TOKEN_FILE}"
fi
RKE2_TOKEN="$(<"${TOKEN_FILE}")"

prepare_node() {
  local vm="$1"
  log "Preparing ${vm}"
  multipass exec "${vm}" -- bash -s <<'EOF'
set -euo pipefail
sudo swapoff -a
sudo sed -i.bak '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab
sudo tee /etc/sysctl.d/99-kubernetes-poc.conf >/dev/null <<SYSCTL
net.ipv4.ip_forward = 1
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
SYSCTL
sudo modprobe overlay
sudo modprobe br_netfilter
sudo sysctl --system >/dev/null
EOF
}

prepare_node "${SERVER_VM}"
prepare_node "${AGENT_VM}"

log "Installing RKE2 server ${RKE2_VERSION}"
multipass exec "${SERVER_VM}" -- \
  env INSTALL_RKE2_VERSION="${RKE2_VERSION}" sh -c \
  'curl -sfL https://get.rke2.io | sudo -E sh -'

multipass exec "${SERVER_VM}" -- bash -s -- "${SERVER_IP}" "${RKE2_TOKEN}" <<'EOF'
set -euo pipefail
server_ip="$1"
token="$2"
sudo mkdir -p /etc/rancher/rke2
sudo tee /etc/rancher/rke2/config.yaml >/dev/null <<CONFIG
token: "${token}"
write-kubeconfig-mode: "0644"
tls-san:
  - "${server_ip}"
node-taint:
  - "node-role.kubernetes.io/control-plane=true:NoSchedule"
disable:
  - rke2-ingress-nginx
CONFIG
sudo systemctl enable --now rke2-server
EOF

log "Waiting for the RKE2 server"
multipass exec "${SERVER_VM}" -- bash -c \
  'until sudo /var/lib/rancher/rke2/bin/kubectl \
    --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes >/dev/null 2>&1; do sleep 5; done'

log "Installing RKE2 agent ${RKE2_VERSION}"
multipass exec "${AGENT_VM}" -- \
  env INSTALL_RKE2_VERSION="${RKE2_VERSION}" INSTALL_RKE2_TYPE="agent" sh -c \
  'curl -sfL https://get.rke2.io | sudo -E sh -'

multipass exec "${AGENT_VM}" -- bash -s -- "${SERVER_IP}" "${RKE2_TOKEN}" <<'EOF'
set -euo pipefail
server_ip="$1"
token="$2"
sudo mkdir -p /etc/rancher/rke2
sudo tee /etc/rancher/rke2/config.yaml >/dev/null <<CONFIG
server: "https://${server_ip}:9345"
token: "${token}"
node-label:
  - "poc.local/workload=kubeflow"
CONFIG
sudo systemctl enable --now rke2-agent
EOF

log "Writing local kubeconfig"
rm -f "${KUBECONFIG_FILE}"
multipass transfer "${SERVER_VM}:/etc/rancher/rke2/rke2.yaml" "${KUBECONFIG_FILE}"
chmod 600 "${KUBECONFIG_FILE}"
python3 - "${KUBECONFIG_FILE}" "${SERVER_IP}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text().replace("127.0.0.1", sys.argv[2]))
PY

export KUBECONFIG="${KUBECONFIG_FILE}"
wait_for_node_ready "${SERVER_VM}"
wait_for_node_ready "${AGENT_VM}"
kubectl label node "${AGENT_VM}" node-role.kubernetes.io/worker=true --overwrite

log "Installing local-path dynamic storage"
kubectl apply -f \
  "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml"
kubectl wait -n local-path-storage --for=condition=Available \
  deployment/local-path-provisioner --timeout=5m
kubectl patch storageclass local-path --type merge \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

log "RKE2 cluster ready"
kubectl get nodes -o wide
kubectl get storageclass

cat <<EOF

Kubeconfig:
  export KUBECONFIG="${KUBECONFIG_FILE}"

Next:
  ${POC_ROOT}/scripts/03-install-kubeflow.sh
EOF
