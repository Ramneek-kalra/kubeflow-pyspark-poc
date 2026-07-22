#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command helm
require_command kubectl
require_command python3
require_cluster

KUBE_PROM_CHART_VERSION="${KUBE_PROM_CHART_VERSION:-75.15.1}"

log "Installing Prometheus + Grafana into monitoring"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts \
  --force-update
helm repo update prometheus-community

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
# Keep monitoring outside the mesh. Istio mTLS breaks Prometheus scrapes, while
# the gateway VirtualService can still reach Grafana without a sidecar.
kubectl label namespace monitoring istio-injection=disabled --overwrite
kubectl label namespace monitoring istio.io/rev- --overwrite 2>/dev/null || true

# Dashboard ConfigMap must exist before the Grafana chart mounts it.
kubectl apply -f "${POC_ROOT}/monitoring/grafana-kubeflow.yaml"

helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version "${KUBE_PROM_CHART_VERSION}" \
  --values "${POC_ROOT}/monitoring/kube-prometheus-values.yaml" \
  --wait \
  --timeout 15m

# Re-apply route/auth after Helm creates Grafana labels/services.
kubectl apply -f "${POC_ROOT}/monitoring/grafana-kubeflow.yaml"

log "Adding Grafana to the Kubeflow Central Dashboard menu"
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
    "link": "/grafana/d/kubeflow-ns/ds-de-kubeflow-workspace?orgId=1&refresh=30s&var-namespace={ns}",
    "text": "Workspace Metrics",
    "icon": "timeline",
}
menu[:] = [
    entry
    for entry in menu
    if entry.get("text") not in ("Grafana", "Workspace Metrics")
]
menu.append(item)
print(json.dumps({"data": {"links": json.dumps(links, indent=4)}}))
'
)"
kubectl -n kubeflow patch configmap dashboard-config \
  --type=merge \
  --patch "${dashboard_patch}"
kubectl -n kubeflow rollout restart deployment/dashboard
kubectl -n kubeflow rollout status deployment/dashboard --timeout=5m

log "Waiting for Grafana and Prometheus"
kubectl -n monitoring rollout status deployment/kps-grafana --timeout=10m
kubectl -n monitoring wait \
  --for=condition=Ready pod \
  -l app.kubernetes.io/name=grafana \
  --timeout=10m

cat <<EOF

Grafana is installed for namespace-scoped Kubeflow dashboards.

Open Kubeflow: http://localhost:${KUBEFLOW_LOCAL_PORT}
Menu item: Workspace Metrics  (opens the selected Profile namespace)

Direct URL pattern:
  /grafana/d/kubeflow-ns/ds-de-kubeflow-workspace?var-namespace=<profile-namespace>

Grafana login (optional; anonymous Viewer is enabled):
  admin / admin
EOF
