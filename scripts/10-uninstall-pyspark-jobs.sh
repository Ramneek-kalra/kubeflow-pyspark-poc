#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command helm
require_command kubectl
require_command python3
require_cluster

if [[ "${1:-}" != "--yes" ]]; then
  cat >&2 <<'EOF'
This removes the PySpark Jobs controller, all per-Profile PySpark Jobs
applications, uploaded-job PVCs, and managed SparkApplications.

It keeps Kubeflow, Spark Operator, and Enterprise Gateway installed.
Run again with --yes to confirm.
EOF
  exit 1
fi

log "Removing the Kubeflow dashboard menu entry"
dashboard_patch="$(
  kubectl -n kubeflow get configmap dashboard-config -o json |
    python3 -c '
import json
import sys

configmap = json.load(sys.stdin)
links = json.loads(configmap["data"]["links"])
menu = links.setdefault("menuLinks", [])
menu[:] = [entry for entry in menu if entry.get("text") != "PySpark Jobs"]
print(json.dumps({"data": {"links": json.dumps(links, indent=4)}}))
'
)"
kubectl -n kubeflow patch configmap dashboard-config \
  --type=merge \
  --patch "${dashboard_patch}"
kubectl -n kubeflow rollout restart deployment/dashboard

log "Removing managed jobs and per-Profile resources"
while IFS= read -r namespace; do
  [[ -n "${namespace}" ]] || continue
  kubectl -n "${namespace}" delete sparkapplications \
    -l app.kubernetes.io/managed-by=pyspark-jobs \
    --ignore-not-found
  kubectl -n "${namespace}" delete \
    deployment,service,pvc,serviceaccount,role,rolebinding,virtualservice \
    -l app.kubernetes.io/managed-by=pyspark-jobs-controller \
    --ignore-not-found
done < <(
  kubectl get profiles.kubeflow.org \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
)

log "Removing the central Profile controller"
kubectl -n kubeflow delete deployment,pod \
  -l app.kubernetes.io/name=pyspark-jobs-controller \
  --ignore-not-found
kubectl -n kubeflow delete serviceaccount pyspark-jobs-controller \
  --ignore-not-found
kubectl delete clusterrolebinding pyspark-jobs-controller --ignore-not-found
kubectl delete clusterrole pyspark-jobs-controller --ignore-not-found
kubectl -n kubeflow delete configmap pyspark-jobs-install-state \
  --ignore-not-found

log "Restoring Spark Operator to Enterprise Gateway only"
helm upgrade spark-operator spark-operator/spark-operator \
  --namespace spark-operator \
  --version 2.5.1 \
  --reuse-values \
  --set-string spark.jobNamespaceSelector="" \
  --set "spark.jobNamespaces={enterprise-gateway}" \
  --wait \
  --timeout 10m

echo "PySpark Jobs was removed; Kubeflow and Enterprise Gateway remain installed."
