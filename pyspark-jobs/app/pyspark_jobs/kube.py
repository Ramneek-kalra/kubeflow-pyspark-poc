from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import shlex
from typing import Any

from kubernetes import client, config
from kubernetes.client import ApiException

from .config import Settings


GROUP = "sparkoperator.k8s.io"
VERSION = "v1beta2"
PLURAL = "sparkapplications"
DNS_LABEL = re.compile(r"[^a-z0-9-]+")


def dns_name(value: str) -> str:
    value = DNS_LABEL.sub("-", value.lower().strip()).strip("-")
    value = re.sub(r"-+", "-", value)[:63].rstrip("-")
    if not value:
        raise ValueError("Job name must contain a letter or number.")
    return value


def load_kubernetes_config() -> None:
    try:
        config.load_incluster_config()
    except config.ConfigException:
        config.load_kube_config()


@dataclass
class JobSummary:
    name: str
    state: str
    created: str
    driver_pod: str | None
    spark_ui_service: str | None
    error: str | None
    file_path: str | None


class SparkJobsClient:
    def __init__(
        self,
        settings: Settings,
        custom_api: client.CustomObjectsApi | None = None,
        core_api: client.CoreV1Api | None = None,
    ) -> None:
        self.settings = settings
        if custom_api is None or core_api is None:
            load_kubernetes_config()
        self.custom = custom_api or client.CustomObjectsApi()
        self.core = core_api or client.CoreV1Api()

    def list_jobs(self) -> list[JobSummary]:
        response = self.custom.list_namespaced_custom_object(
            GROUP, VERSION, self.settings.namespace, PLURAL
        )
        jobs = [self._summary(item) for item in response.get("items", [])]
        return sorted(jobs, key=lambda item: item.created, reverse=True)

    def get_job(self, name: str) -> dict[str, Any]:
        return self.custom.get_namespaced_custom_object(
            GROUP, VERSION, self.settings.namespace, PLURAL, dns_name(name)
        )

    def get_summary(self, name: str) -> JobSummary:
        return self._summary(self.get_job(name))

    def submit_job(
        self,
        *,
        name: str,
        relative_file: str,
        arguments: str,
        driver_cores: int,
        driver_memory: str,
        executor_cores: int,
        executor_memory: str,
        executor_instances: int,
        submitted_by: str,
    ) -> dict[str, Any]:
        job_name = dns_name(name)
        args = shlex.split(arguments)
        mount_path = f"/opt/spark/jobs/{relative_file}"
        base = self.settings.base_path
        labels = {
            "app.kubernetes.io/managed-by": "pyspark-jobs",
            "pyspark-jobs/profile": self.settings.namespace,
        }
        resource = {
            "apiVersion": f"{GROUP}/{VERSION}",
            "kind": "SparkApplication",
            "metadata": {
                "name": job_name,
                "namespace": self.settings.namespace,
                "labels": labels,
                "annotations": {
                    "pyspark-jobs/file-path": relative_file,
                    "pyspark-jobs/submitted-by": submitted_by,
                },
            },
            "spec": {
                "type": "Python",
                "pythonVersion": "3",
                "mode": "cluster",
                "image": self.settings.spark_image,
                "imagePullPolicy": "IfNotPresent",
                "mainApplicationFile": f"local://{mount_path}",
                "sparkVersion": self.settings.spark_version,
                "arguments": args,
                "restartPolicy": {"type": "Never"},
                "nodeSelector": {
                    self.settings.node_selector_key: (
                        self.settings.node_selector_value
                    )
                },
                "sparkConf": {
                    "spark.ui.proxyBase": (
                        f"{base}/jobs/{job_name}/spark-ui"
                    ),
                    (
                        "spark.kubernetes.driver.volumes."
                        "persistentVolumeClaim.jobs.options.claimName"
                    ): self.settings.workspace_pvc,
                    (
                        "spark.kubernetes.driver.volumes."
                        "persistentVolumeClaim.jobs.mount.path"
                    ): "/opt/spark/jobs",
                    (
                        "spark.kubernetes.executor.volumes."
                        "persistentVolumeClaim.jobs.options.claimName"
                    ): self.settings.workspace_pvc,
                    (
                        "spark.kubernetes.executor.volumes."
                        "persistentVolumeClaim.jobs.mount.path"
                    ): "/opt/spark/jobs",
                },
                "driver": {
                    "cores": driver_cores,
                    "memory": driver_memory,
                    "serviceAccount": self.settings.runner_service_account,
                    "labels": labels,
                    "annotations": {"sidecar.istio.io/inject": "false"},
                },
                "executor": {
                    "cores": executor_cores,
                    "instances": executor_instances,
                    "memory": executor_memory,
                    "labels": labels,
                    "annotations": {"sidecar.istio.io/inject": "false"},
                },
                "sparkUIOptions": {
                    "serviceType": "ClusterIP",
                    "servicePortName": "http-spark-ui",
                },
            },
        }
        return self.custom.create_namespaced_custom_object(
            GROUP,
            VERSION,
            self.settings.namespace,
            PLURAL,
            resource,
        )

    def delete_job(self, name: str) -> str | None:
        resource = self.get_job(name)
        relative_file = (
            resource.get("metadata", {})
            .get("annotations", {})
            .get("pyspark-jobs/file-path")
        )
        self.custom.delete_namespaced_custom_object(
            GROUP,
            VERSION,
            self.settings.namespace,
            PLURAL,
            dns_name(name),
            body=client.V1DeleteOptions(
                propagation_policy="Background"
            ),
        )
        return relative_file

    def driver_logs(self, name: str, tail_lines: int = 500) -> str:
        summary = self.get_summary(name)
        if not summary.driver_pod:
            return "Driver pod has not been created yet."
        return self.core.read_namespaced_pod_log(
            summary.driver_pod,
            self.settings.namespace,
            tail_lines=tail_lines,
            timestamps=True,
        )

    def events(self, name: str) -> list[dict[str, str]]:
        response = self.core.list_namespaced_event(
            self.settings.namespace,
            field_selector=f"involvedObject.name={dns_name(name)}",
        )
        result = []
        for event in response.items:
            result.append(
                {
                    "type": event.type or "",
                    "reason": event.reason or "",
                    "message": event.message or "",
                    "time": str(
                        event.last_timestamp
                        or event.event_time
                        or event.metadata.creation_timestamp
                        or ""
                    ),
                }
            )
        return result

    def spark_ui_service(self, name: str) -> str:
        summary = self.get_summary(name)
        service = summary.spark_ui_service
        if not service:
            raise ValueError("Spark UI service is not available yet.")
        if not re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", service):
            raise ValueError("Spark UI returned an invalid service name.")
        return service

    @staticmethod
    def _summary(resource: dict[str, Any]) -> JobSummary:
        metadata = resource.get("metadata", {})
        status = resource.get("status", {})
        app_state = status.get("applicationState", {})
        driver = status.get("driverInfo", {})
        state = app_state.get("state") or "SUBMITTED"
        error = app_state.get("errorMessage") or status.get("errorMessage")
        annotations = metadata.get("annotations", {})
        return JobSummary(
            name=metadata.get("name", ""),
            state=state,
            created=metadata.get("creationTimestamp", ""),
            driver_pod=driver.get("podName"),
            spark_ui_service=driver.get("webUIServiceName"),
            error=error,
            file_path=annotations.get("pyspark-jobs/file-path"),
        )


def safe_job_directory(root: Path, relative_file: str) -> Path:
    target = (root / relative_file).resolve().parent
    resolved_root = root.resolve()
    if target == resolved_root or resolved_root not in target.parents:
        raise ValueError("Invalid job file path.")
    return target


__all__ = [
    "ApiException",
    "JobSummary",
    "SparkJobsClient",
    "dns_name",
    "safe_job_directory",
]
