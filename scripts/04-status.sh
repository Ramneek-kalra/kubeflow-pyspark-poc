#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_command multipass
require_command kubectl

echo "=== Multipass VMs ==="
multipass list | awk 'NR == 1 || /poc-kf-rke2/'

require_cluster

echo
echo "=== Nodes ==="
kubectl get nodes -o wide

echo
echo "=== Storage ==="
kubectl get storageclass

echo
echo "=== Kubeflow namespaces ==="
kubectl get namespaces |
  awk 'NR == 1 || /kubeflow|istio|auth|oauth2|cert-manager|profiles|katib/'

echo
echo "=== Non-healthy pods ==="
unhealthy="$(
  kubectl get pods -A --no-headers |
    awk '$4 != "Running" && $4 != "Completed" && $4 != "Succeeded" {print}'
)"
if [[ -n "${unhealthy}" ]]; then
  echo "${unhealthy}"
else
  echo "None"
fi

echo
echo "=== Kubeflow version pins ==="
echo "RKE2:     ${RKE2_VERSION}"
echo "Kubeflow: ${KUBEFLOW_VERSION}"
echo "Profile:  ${KUBEFLOW_PROFILE}"

echo
echo "=== Spark integration ==="
if kubectl get crd sparkapplications.sparkoperator.k8s.io >/dev/null 2>&1; then
  kubectl -n spark-operator get deployment
  kubectl get sparkapplications.sparkoperator.k8s.io -A
else
  echo "Spark Operator: not installed"
fi

echo
echo "=== PySpark Jobs ==="
if kubectl -n kubeflow get deployment pyspark-jobs-controller >/dev/null 2>&1; then
  kubectl -n kubeflow get deployment pyspark-jobs-controller
  kubectl get deployments,services,pvc -A \
    -l app.kubernetes.io/name=pyspark-jobs
else
  echo "PySpark Jobs: not installed"
fi

echo
echo "=== Grafana / Prometheus ==="
if kubectl -n monitoring get deployment kps-grafana >/dev/null 2>&1; then
  kubectl -n monitoring get deployment,sts,svc
else
  echo "Grafana: not installed"
fi
