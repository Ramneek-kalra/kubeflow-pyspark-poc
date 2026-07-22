#!/usr/bin/env bash
# Enable Notebook Controller idle culling so Kubeflow fills status.lastActivity
# (the Notebooks UI "Last activity" column). Idle notebooks scale to zero after
# CULL_IDLE_TIME minutes (default 1440 = 24h).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command kubectl
require_cluster

ENABLE_CULLING="${ENABLE_CULLING:-true}"
CULL_IDLE_TIME="${CULL_IDLE_TIME:-1440}"
IDLENESS_CHECK_PERIOD="${IDLENESS_CHECK_PERIOD:-1}"

CM="$(
  kubectl -n kubeflow get configmap -l app=notebook-controller \
    -o jsonpath='{.items[0].metadata.name}'
)"
[[ -n "${CM}" ]] || die "notebook-controller ConfigMap not found in kubeflow"

log "Enabling notebook culling on ${CM}"
kubectl -n kubeflow patch configmap "${CM}" --type merge -p "$(
  cat <<EOF
{"data":{"ENABLE_CULLING":"${ENABLE_CULLING}","CULL_IDLE_TIME":"${CULL_IDLE_TIME}","IDLENESS_CHECK_PERIOD":"${IDLENESS_CHECK_PERIOD}"}}
EOF
)"

kubectl -n kubeflow rollout restart deployment/notebook-controller-deployment
kubectl -n kubeflow rollout status deployment/notebook-controller-deployment --timeout=3m

log "Culling enabled (idle stop after ${CULL_IDLE_TIME}m, check every ${IDLENESS_CHECK_PERIOD}m)"
log "Refresh Notebooks UI — Last activity should populate within ~1-2 check periods."
