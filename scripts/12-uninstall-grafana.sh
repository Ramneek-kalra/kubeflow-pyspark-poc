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
This removes Prometheus/Grafana from the monitoring namespace and the Kubeflow
Grafana menu entry. Run again with --yes to confirm.
EOF
  exit 1
fi

log "Removing Grafana from the Kubeflow dashboard menu"
dashboard_patch="$(
  kubectl -n kubeflow get configmap dashboard-config -o json |
    python3 -c '
import json
import sys

configmap = json.load(sys.stdin)
links = json.loads(configmap["data"]["links"])
menu = links.setdefault("menuLinks", [])
menu[:] = [
    entry
    for entry in menu
    if entry.get("text") not in ("Grafana", "Workspace Metrics")
]
print(json.dumps({"data": {"links": json.dumps(links, indent=4)}}))
'
)"
kubectl -n kubeflow patch configmap dashboard-config \
  --type=merge \
  --patch "${dashboard_patch}"
kubectl -n kubeflow rollout restart deployment/dashboard

log "Uninstalling the monitoring stack"
helm uninstall kps -n monitoring --wait --timeout 10m || true
kubectl -n monitoring delete \
  configmap/grafana-kubeflow-namespace-dashboard \
  virtualservice/grafana \
  authorizationpolicy/grafana \
  --ignore-not-found
kubectl delete namespace monitoring --ignore-not-found

echo "Grafana/Prometheus removed."
