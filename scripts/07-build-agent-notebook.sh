#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command docker
require_command multipass

IMAGE="docker.io/kubeflowpoc/kubeflow-user-notebook-ai:3.0.1-eg3"
ARCHIVE="${STATE_DIR}/kubeflow-user-notebook-ai-3.0.1-eg3.tar"
REMOTE_ARCHIVE="/tmp/kubeflow-user-notebook-ai-3.0.1-eg3.tar"

log "Building ${IMAGE} for the ARM64 RKE2 worker"
docker build --platform linux/arm64 \
  --tag "${IMAGE}" \
  "${POC_ROOT}/notebook-agent"

log "Exporting image"
docker save --output "${ARCHIVE}" "${IMAGE}"

log "Loading image into ${AGENT_VM} RKE2 containerd"
multipass transfer "${ARCHIVE}" "${AGENT_VM}:${REMOTE_ARCHIVE}"
multipass exec "${AGENT_VM}" -- sudo \
  /var/lib/rancher/rke2/bin/ctr \
  --address /run/k3s/containerd/containerd.sock \
  --namespace k8s.io images import "${REMOTE_ARCHIVE}"
multipass exec "${AGENT_VM}" -- rm -f "${REMOTE_ARCHIVE}"
rm -f "${ARCHIVE}"

log "Image available on the worker"
multipass exec "${AGENT_VM}" -- sudo \
  /var/lib/rancher/rke2/bin/ctr \
  --address /run/k3s/containerd/containerd.sock \
  --namespace k8s.io images list |
  grep 'kubeflowpoc/kubeflow-user-notebook-ai'
