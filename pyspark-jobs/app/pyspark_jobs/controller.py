from __future__ import annotations

import logging
import os
import time
from typing import Any

from kubernetes import client, config, dynamic, watch
from kubernetes.client import ApiException


LOG = logging.getLogger("pyspark-jobs-controller")
MANAGED_LABELS = {
    "app.kubernetes.io/name": "pyspark-jobs",
    "app.kubernetes.io/managed-by": "pyspark-jobs-controller",
}


def profile_resources(
    namespace: str,
    image: str,
    storage_class: str = "local-path",
) -> list[dict[str, Any]]:
    base_path = f"/pyspark-jobs/{namespace}"
    labels = {**MANAGED_LABELS, "pyspark-jobs/profile": namespace}
    pod_labels = {**labels, "app.kubernetes.io/component": "ui"}
    resources: list[dict[str, Any]] = [
        {
            "apiVersion": "v1",
            "kind": "PersistentVolumeClaim",
            "metadata": {
                "name": "pyspark-jobs-workspace",
                "namespace": namespace,
                "labels": labels,
            },
            "spec": {
                "accessModes": ["ReadWriteOnce"],
                "storageClassName": storage_class,
                "resources": {"requests": {"storage": "1Gi"}},
            },
        },
        *[
            {
                "apiVersion": "v1",
                "kind": "ServiceAccount",
                "metadata": {
                    "name": name,
                    "namespace": namespace,
                    "labels": labels,
                },
            }
            for name in ("pyspark-jobs-ui", "pyspark-jobs-runner")
        ],
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "Role",
            "metadata": {
                "name": "pyspark-jobs-ui",
                "namespace": namespace,
                "labels": labels,
            },
            "rules": [
                {
                    "apiGroups": ["sparkoperator.k8s.io"],
                    "resources": ["sparkapplications"],
                    "verbs": ["create", "delete", "get", "list", "watch"],
                },
                {
                    "apiGroups": [""],
                    "resources": ["pods", "pods/log", "events", "services"],
                    "verbs": ["get", "list", "watch"],
                },
            ],
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "RoleBinding",
            "metadata": {
                "name": "pyspark-jobs-ui",
                "namespace": namespace,
                "labels": labels,
            },
            "roleRef": {
                "apiGroup": "rbac.authorization.k8s.io",
                "kind": "Role",
                "name": "pyspark-jobs-ui",
            },
            "subjects": [
                {
                    "kind": "ServiceAccount",
                    "name": "pyspark-jobs-ui",
                    "namespace": namespace,
                }
            ],
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "Role",
            "metadata": {
                "name": "pyspark-jobs-runner",
                "namespace": namespace,
                "labels": labels,
            },
            "rules": [
                {
                    "apiGroups": [""],
                    "resources": ["pods", "services", "configmaps"],
                    "verbs": [
                        "create",
                        "delete",
                        "get",
                        "list",
                        "patch",
                        "update",
                        "watch",
                    ],
                },
                {
                    "apiGroups": [""],
                    "resources": ["persistentvolumeclaims"],
                    "verbs": ["get", "list"],
                },
            ],
        },
        {
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "RoleBinding",
            "metadata": {
                "name": "pyspark-jobs-runner",
                "namespace": namespace,
                "labels": labels,
            },
            "roleRef": {
                "apiGroup": "rbac.authorization.k8s.io",
                "kind": "Role",
                "name": "pyspark-jobs-runner",
            },
            "subjects": [
                {
                    "kind": "ServiceAccount",
                    "name": "pyspark-jobs-runner",
                    "namespace": namespace,
                }
            ],
        },
        {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {
                "name": "pyspark-jobs",
                "namespace": namespace,
                "labels": labels,
            },
            "spec": {
                "replicas": 1,
                "selector": {"matchLabels": pod_labels},
                "template": {
                    "metadata": {
                        "labels": pod_labels,
                        "annotations": {
                            "sidecar.istio.io/inject": "true",
                        },
                    },
                    "spec": {
                        "serviceAccountName": "pyspark-jobs-ui",
                        "nodeSelector": {
                            "poc.local/workload": "kubeflow"
                        },
                        "securityContext": {
                            "runAsNonRoot": True,
                            "runAsUser": 1000,
                            "runAsGroup": 1000,
                            "fsGroup": 1000,
                            "seccompProfile": {
                                "type": "RuntimeDefault"
                            },
                        },
                        "containers": [
                            {
                                "name": "ui",
                                "image": image,
                                "imagePullPolicy": "IfNotPresent",
                                "ports": [
                                    {"name": "http", "containerPort": 8080}
                                ],
                                "env": [
                                    {
                                        "name": "PROFILE_NAMESPACE",
                                        "value": namespace,
                                    },
                                    {"name": "BASE_PATH", "value": base_path},
                                    {"name": "JOBS_ROOT", "value": "/jobs"},
                                    {
                                        "name": "REQUIRE_USER_HEADER",
                                        "value": "true",
                                    },
                                ],
                                "resources": {
                                    "requests": {
                                        "cpu": "100m",
                                        "memory": "128Mi",
                                    },
                                    "limits": {
                                        "cpu": "500m",
                                        "memory": "512Mi",
                                    },
                                },
                                "securityContext": {
                                    "allowPrivilegeEscalation": False,
                                    "capabilities": {"drop": ["ALL"]},
                                    "readOnlyRootFilesystem": True,
                                },
                                "readinessProbe": {
                                    "httpGet": {
                                        "path": "/healthz",
                                        "port": "http",
                                    },
                                    "initialDelaySeconds": 3,
                                    "periodSeconds": 5,
                                },
                                "livenessProbe": {
                                    "httpGet": {
                                        "path": "/healthz",
                                        "port": "http",
                                    },
                                    "initialDelaySeconds": 10,
                                    "periodSeconds": 10,
                                },
                                "volumeMounts": [
                                    {"name": "jobs", "mountPath": "/jobs"},
                                    {"name": "tmp", "mountPath": "/tmp"},
                                ],
                            }
                        ],
                        "volumes": [
                            {
                                "name": "jobs",
                                "persistentVolumeClaim": {
                                    "claimName": "pyspark-jobs-workspace"
                                },
                            },
                            {"name": "tmp", "emptyDir": {}},
                        ],
                    },
                },
            },
        },
        {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {
                "name": "pyspark-jobs",
                "namespace": namespace,
                "labels": labels,
            },
            "spec": {
                "selector": pod_labels,
                "ports": [{"name": "http", "port": 80, "targetPort": "http"}],
            },
        },
        {
            "apiVersion": "networking.istio.io/v1beta1",
            "kind": "VirtualService",
            "metadata": {
                "name": "pyspark-jobs",
                "namespace": namespace,
                "labels": labels,
            },
            "spec": {
                "gateways": ["kubeflow/kubeflow-gateway"],
                "hosts": ["*"],
                "http": [
                    {
                        "match": [{"uri": {"prefix": f"{base_path}/"}}],
                        "rewrite": {"uri": "/"},
                        "headers": {
                            "request": {
                                "set": {"x-forwarded-prefix": base_path}
                            }
                        },
                        "route": [
                            {
                                "destination": {
                                    "host": (
                                        f"pyspark-jobs.{namespace}.svc.cluster.local"
                                    ),
                                    "port": {"number": 80},
                                }
                            }
                        ],
                    },
                    {
                        "match": [{"uri": {"exact": base_path}}],
                        "redirect": {"uri": f"{base_path}/"},
                    },
                ],
            },
        },
    ]
    return resources


class ProfileController:
    def __init__(self) -> None:
        config.load_incluster_config()
        self.api_client = client.ApiClient()
        self.dynamic = dynamic.DynamicClient(self.api_client)
        self.custom = client.CustomObjectsApi(self.api_client)
        self.image = os.environ["JOBS_IMAGE"]
        self.storage_class = os.environ.get("STORAGE_CLASS", "local-path")

    def apply(self, manifest: dict[str, Any]) -> None:
        resource = self.dynamic.resources.get(
            api_version=manifest["apiVersion"], kind=manifest["kind"]
        )
        metadata = manifest["metadata"]
        namespace = metadata.get("namespace")
        name = metadata["name"]
        try:
            resource.get(name=name, namespace=namespace)
        except ApiException as error:
            if error.status != 404:
                raise
            resource.create(body=manifest, namespace=namespace)
            LOG.info("Created %s/%s in %s", manifest["kind"], name, namespace)
            return
        resource.patch(
            name=name,
            namespace=namespace,
            body=manifest,
            content_type="application/merge-patch+json",
        )
        LOG.info("Reconciled %s/%s in %s", manifest["kind"], name, namespace)

    def reconcile(self, profile: dict[str, Any]) -> None:
        namespace = profile.get("metadata", {}).get("name")
        if not namespace:
            return
        for manifest in profile_resources(
            namespace, self.image, self.storage_class
        ):
            self.apply(manifest)

    def run(self) -> None:
        while True:
            try:
                profiles = self.custom.list_cluster_custom_object(
                    "kubeflow.org", "v1", "profiles"
                )
                for profile in profiles.get("items", []):
                    self.reconcile(profile)

                stream = watch.Watch()
                for event in stream.stream(
                    self.custom.list_cluster_custom_object,
                    "kubeflow.org",
                    "v1",
                    "profiles",
                    timeout_seconds=60,
                ):
                    if event["type"] in {"ADDED", "MODIFIED"}:
                        self.reconcile(event["object"])
            except Exception:
                LOG.exception("Profile watch failed; retrying")
                time.sleep(5)


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    ProfileController().run()


if __name__ == "__main__":
    main()
