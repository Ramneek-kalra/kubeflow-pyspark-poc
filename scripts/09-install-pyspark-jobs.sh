#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command docker
require_command helm
require_command kubectl
require_command multipass
require_command python3
require_cluster

PYSPARK_JOBS_IMAGE="${PYSPARK_JOBS_IMAGE:-docker.io/kubeflowpoc/kubeflow-pyspark-jobs:0.1.0-arm64}"
ARCHIVE="${STATE_DIR}/kubeflow-pyspark-jobs-0.1.0-arm64.tar"
REMOTE_ARCHIVE="/tmp/kubeflow-pyspark-jobs-0.1.0-arm64.tar"
SPARK_OPERATOR_VERSION="${SPARK_OPERATOR_VERSION:-2.5.1}"

if [[ "${SKIP_IMAGE_BUILD:-false}" != "true" ]]; then
  log "Building ${PYSPARK_JOBS_IMAGE} for the ARM64 RKE2 worker"
  docker build --platform linux/arm64 \
    --tag "${PYSPARK_JOBS_IMAGE}" \
    "${POC_ROOT}/pyspark-jobs"

  log "Preloading the PySpark Jobs image into RKE2 containerd"
  docker save --output "${ARCHIVE}" "${PYSPARK_JOBS_IMAGE}"
  multipass transfer "${ARCHIVE}" "${AGENT_VM}:${REMOTE_ARCHIVE}"
  multipass exec "${AGENT_VM}" -- sudo \
    /var/lib/rancher/rke2/bin/ctr \
    --address /run/k3s/containerd/containerd.sock \
    --namespace k8s.io images import "${REMOTE_ARCHIVE}"
  multipass exec "${AGENT_VM}" -- rm -f "${REMOTE_ARCHIVE}"
  rm -f "${ARCHIVE}"
fi

if ! kubectl -n kubeflow get configmap pyspark-jobs-install-state \
  >/dev/null 2>&1; then
  log "Removing stale, unprocessed Enterprise Gateway SparkApplications once"
  stale_names="$(
    kubectl -n enterprise-gateway get sparkapplications \
      -o json 2>/dev/null |
      python3 -c '
import json
import sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    if not item.get("status"):
        print(item["metadata"]["name"])
' || true
  )"
  if [[ -n "${stale_names}" ]]; then
    while IFS= read -r name; do
      kubectl -n enterprise-gateway delete sparkapplication "${name}" \
        --ignore-not-found
    done <<<"${stale_names}"
  fi
  kubectl -n kubeflow create configmap pyspark-jobs-install-state \
    --from-literal=stale-enterprise-gateway-cleanup=completed
fi

log "Upgrading Spark Operator ${SPARK_OPERATOR_VERSION} namespace scope"
helm repo add spark-operator https://kubeflow.github.io/spark-operator \
  --force-update
helm repo update spark-operator
helm upgrade --install spark-operator spark-operator/spark-operator \
  --namespace spark-operator \
  --create-namespace \
  --version "${SPARK_OPERATOR_VERSION}" \
  --values "${POC_ROOT}/pyspark-jobs/spark-operator-values.yaml" \
  --wait \
  --timeout 10m

log "Installing the Profile reconciler"
sed "s|\${PYSPARK_JOBS_IMAGE}|${PYSPARK_JOBS_IMAGE}|g" \
  "${POC_ROOT}/pyspark-jobs/controller.yaml" |
  kubectl apply -f -
kubectl -n kubeflow rollout restart deployment/pyspark-jobs-controller
kubectl -n kubeflow rollout status deployment/pyspark-jobs-controller \
  --timeout=5m

log "Adding the PySpark Jobs menu to Kubeflow"
dashboard_patch="$(
  kubectl -n kubeflow get configmap dashboard-config -o json |
    python3 -c '
import json
import sys

configmap = json.load(sys.stdin)
links = json.loads(configmap["data"]["links"])
menu = links.setdefault("menuLinks", [])
item = {
    "type": "item",
    "link": "/pyspark-jobs/{ns}/",
    "text": "PySpark Jobs",
    "icon": "assessment",
}
menu[:] = [entry for entry in menu if entry.get("text") != "PySpark Jobs"]
menu.append(item)
print(json.dumps({"data": {"links": json.dumps(links, indent=4)}}))
'
)"
kubectl -n kubeflow patch configmap dashboard-config \
  --type=merge \
  --patch "${dashboard_patch}"
kubectl -n kubeflow rollout restart deployment/dashboard
kubectl -n kubeflow rollout status deployment/dashboard --timeout=5m

log "Waiting for each current Profile application"
while IFS= read -r namespace; do
  [[ -n "${namespace}" ]] || continue
  for attempt in $(seq 1 60); do
    if kubectl -n "${namespace}" get deployment pyspark-jobs \
      >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  kubectl -n "${namespace}" get deployment pyspark-jobs >/dev/null ||
    die "Profile reconciler did not create pyspark-jobs in ${namespace}."
  kubectl -n "${namespace}" rollout restart deployment/pyspark-jobs
  kubectl -n "${namespace}" rollout status deployment/pyspark-jobs \
    --timeout=5m
  kubectl -n "${namespace}" wait \
    --for=jsonpath='{.status.phase}'=Bound \
    pvc/pyspark-jobs-workspace \
    --timeout=5m
done < <(
  kubectl get profiles.kubeflow.org \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
)

log "PySpark Jobs installation complete"
kubectl get sparkapplications.sparkoperator.k8s.io -A
kubectl get deployments,services,pvc -A \
  -l app.kubernetes.io/name=pyspark-jobs
