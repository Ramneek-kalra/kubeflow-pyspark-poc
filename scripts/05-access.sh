#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command kubectl
require_cluster

cat <<EOF
Kubeflow URL: http://localhost:${KUBEFLOW_LOCAL_PORT}
Username:     user@example.com
Password:     12341234

Keep this command running. Press Ctrl-C to stop access.
EOF

exec kubectl port-forward -n istio-system \
  service/istio-ingressgateway "${KUBEFLOW_LOCAL_PORT}:80"
