#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command kubectl
require_cluster

NAMESPACE="kubeflow-user-example-com"
NOTEBOOK="${NOTEBOOK:-test-spark}"
IMAGE="docker.io/kubeflowpoc/kubeflow-user-notebook-ai:3.0.1-eg3"

kubectl get notebook "${NOTEBOOK}" -n "${NAMESPACE}" >/dev/null 2>&1 ||
  die "User Notebook ${NAMESPACE}/${NOTEBOOK} does not exist."

container_name="$(
  kubectl get notebook "${NOTEBOOK}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].name}'
)"
[[ -n "${container_name}" ]] || die "Notebook has no primary container."

log "Adding Jupyter AI to the existing ${NOTEBOOK} user Notebook"
kubectl patch notebook "${NOTEBOOK}" -n "${NAMESPACE}" --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${IMAGE}\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"IfNotPresent\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/cpu\",\"value\":\"1\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/memory\",\"value\":\"1Gi\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/cpu\",\"value\":\"2\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"3Gi\"}
]"

old_pod="$(
  kubectl get pods -n "${NAMESPACE}" \
    -l "notebook-name=${NOTEBOOK}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
)"
if [[ -n "${old_pod}" ]]; then
  kubectl delete pod "${old_pod}" -n "${NAMESPACE}" --wait=true
fi

log "Waiting for updated user Notebook pod"
for _ in $(seq 1 60); do
  pod="$(
    kubectl get pods -n "${NAMESPACE}" \
      -l "notebook-name=${NOTEBOOK}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
  )"
  [[ -n "${pod}" ]] && break
  sleep 5
done
[[ -n "${pod:-}" ]] || die "Notebook pod was not created."

kubectl wait -n "${NAMESPACE}" \
  --for=condition=Ready "pod/${pod}" --timeout=15m

log "Jupyter AI is integrated into ${NOTEBOOK}"
kubectl get notebook "${NOTEBOOK}" -n "${NAMESPACE}"
kubectl get pod "${pod}" -n "${NAMESPACE}" -o wide

# Remove the superseded standalone agent notebook only after the user Notebook
# is healthy. Its dedicated PVC is not used by the user Notebook.
kubectl delete notebook agentic-pyspark -n "${NAMESPACE}" --ignore-not-found
kubectl delete pvc agentic-notebook-workspace -n "${NAMESPACE}" --ignore-not-found

cat <<EOF

Open http://localhost:${KUBEFLOW_LOCAL_PORT}
Navigate to Notebooks and connect to '${NOTEBOOK}'.
In JupyterLab, open Chat and mention @OpenCode.
EOF
