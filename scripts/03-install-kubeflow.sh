#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command curl
require_command git
require_cluster

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "${ARCH}" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64) ARCH="amd64" ;;
  *) die "Unsupported architecture: ${ARCH}" ;;
esac

KUSTOMIZE_BIN="${TOOLS_DIR}/kustomize"
KUBECTL_BIN="${TOOLS_DIR}/kubectl"

install_tools() {
  if [[ ! -x "${KUSTOMIZE_BIN}" ]] ||
    [[ "$("${KUSTOMIZE_BIN}" version 2>/dev/null || true)" != *"v${KUSTOMIZE_VERSION}"* ]]; then
    log "Installing kustomize ${KUSTOMIZE_VERSION}"
    tmp="$(mktemp -d)"
    curl -fsSL \
      "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_${OS}_${ARCH}.tar.gz" |
      tar -xz -C "${tmp}"
    mv "${tmp}/kustomize" "${KUSTOMIZE_BIN}"
    chmod +x "${KUSTOMIZE_BIN}"
    rm -rf "${tmp}"
  fi

  if [[ ! -x "${KUBECTL_BIN}" ]] ||
    [[ "$("${KUBECTL_BIN}" version --client -o json 2>/dev/null || true)" != *"${KUBERNETES_VERSION}"* ]]; then
    log "Installing kubectl ${KUBERNETES_VERSION}"
    curl -fsSLo "${KUBECTL_BIN}" \
      "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/${OS}/${ARCH}/kubectl"
    curl -fsSLo "${KUBECTL_BIN}.sha256" \
      "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/${OS}/${ARCH}/kubectl.sha256"
    (
      cd "${TOOLS_DIR}"
      echo "$(cat kubectl.sha256)  kubectl" | shasum -a 256 --check
    )
    chmod +x "${KUBECTL_BIN}"
  fi
}

install_tools

if [[ ! -d "${MANIFESTS_DIR}/.git" ]]; then
  log "Cloning Kubeflow community distribution ${KUBEFLOW_VERSION}"
  git clone --depth 1 --branch "${KUBEFLOW_VERSION}" \
    https://github.com/kubeflow/manifests.git "${MANIFESTS_DIR}"
else
  current_ref="$(git -C "${MANIFESTS_DIR}" describe --tags --exact-match 2>/dev/null || true)"
  [[ "${current_ref}" == "${KUBEFLOW_VERSION}" ]] ||
    die "${MANIFESTS_DIR} is not at ${KUBEFLOW_VERSION}; remove it and rerun."
fi

case "${KUBEFLOW_PROFILE}" in
  core)
    log "Preparing resource-conscious core Kubeflow overlay"
    mkdir -p "${MANIFESTS_DIR}/poc-rke2"
    cp "${POC_ROOT}/kubeflow/core-kustomization.yaml" \
      "${MANIFESTS_DIR}/poc-rke2/kustomization.yaml"
    KUSTOMIZATION="${MANIFESTS_DIR}/poc-rke2"
    ;;
  full)
    log "Preparing full Kubeflow overlay without Spark Operator"
    python3 - "${MANIFESTS_DIR}/example/kustomization.yaml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "- ../applications/spark/spark-operator/overlays/kubeflow",
    "# Spark Operator intentionally omitted for the manual POC phase",
)
path.write_text(text)
PY
    KUSTOMIZATION="${MANIFESTS_DIR}/example"
    ;;
  *)
    die "KUBEFLOW_PROFILE must be 'core' or 'full', got: ${KUBEFLOW_PROFILE}"
    ;;
esac

log "Rendering Kubeflow manifests before applying"
"${KUSTOMIZE_BIN}" build "${KUSTOMIZATION}" >/dev/null

log "Installing Kubeflow ${KUBEFLOW_VERSION} (${KUBEFLOW_PROFILE} profile)"
# Kubeflow contains webhooks that become ready during installation. Reapplying
# is expected and is the approach used by the upstream manifests project.
installed=false
for attempt in $(seq 1 20); do
  echo "Apply attempt ${attempt}/20"
  if "${KUSTOMIZE_BIN}" build "${KUSTOMIZATION}" |
    "${KUBECTL_BIN}" apply --server-side --force-conflicts \
      --request-timeout=60s -f -; then
    installed=true
    break
  fi
  sleep 15
done
[[ "${installed}" == "true" ]] || die "Kubeflow manifests did not apply successfully."

log "Applying RKE2 Canal NetworkPolicy compatibility"
"${KUBECTL_BIN}" apply -f "${POC_ROOT}/kubeflow/rke2-networkpolicy.yaml"

log "Waiting for primary platform deployments (this can take 15-30 minutes)"
for target in \
  "cert-manager/cert-manager" \
  "istio-system/istiod" \
  "auth/dex" \
  "oauth2-proxy/oauth2-proxy" \
  "profiles-system/profiles-deployment" \
  "kubeflow/centraldashboard" \
  "kubeflow/jupyter-web-app-deployment" \
  "kubeflow/ml-pipeline-ui"; do
  namespace="${target%%/*}"
  deployment="${target#*/}"
  if "${KUBECTL_BIN}" get deployment "${deployment}" -n "${namespace}" >/dev/null 2>&1; then
    "${KUBECTL_BIN}" wait -n "${namespace}" \
      --for=condition=Available "deployment/${deployment}" --timeout=20m
  fi
done

log "Kubeflow installation summary"
"${KUBECTL_BIN}" get nodes
"${KUBECTL_BIN}" get pods -A |
  awk 'NR == 1 || /kubeflow|istio|auth|oauth2|cert-manager|profiles|katib/'

cat <<EOF

Kubeflow ${KUBEFLOW_VERSION} is installed.
Spark Operator and Jupyter Enterprise Gateway were intentionally not installed.

Access:
  ${POC_ROOT}/scripts/05-access.sh
EOF
