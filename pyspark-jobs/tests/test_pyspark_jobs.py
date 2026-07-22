from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from pyspark_jobs.config import Settings
from pyspark_jobs.controller import profile_resources
from pyspark_jobs.kube import SparkJobsClient, dns_name, safe_job_directory
from pyspark_jobs import main


class FakeCustomApi:
    def __init__(self) -> None:
        self.created = None
        self.deleted = None
        self.job = {
            "metadata": {
                "name": "demo",
                "namespace": "profile-a",
                "creationTimestamp": "2026-07-22T00:00:00Z",
                "annotations": {"pyspark-jobs/file-path": "demo-123/demo.py"},
            },
            "status": {
                "applicationState": {"state": "RUNNING"},
                "driverInfo": {
                    "podName": "demo-driver",
                    "webUIServiceName": "demo-ui-svc",
                },
            },
        }

    def list_namespaced_custom_object(self, *args, **kwargs):
        return {"items": [self.job]}

    def get_namespaced_custom_object(self, *args, **kwargs):
        return self.job

    def create_namespaced_custom_object(self, *args, **kwargs):
        self.created = args[-1]
        return self.created

    def delete_namespaced_custom_object(self, *args, **kwargs):
        self.deleted = args[4]
        return {}


class FakeCoreApi:
    def read_namespaced_pod_log(self, name, namespace, **kwargs):
        return f"{namespace}/{name}: log"

    def list_namespaced_event(self, *args, **kwargs):
        return SimpleNamespace(items=[])


@pytest.fixture
def cfg(tmp_path: Path) -> Settings:
    return Settings(
        namespace="profile-a",
        jobs_root=tmp_path,
        base_path="/pyspark-jobs/profile-a",
        spark_image="apache/spark:3.5.5",
        spark_version="3.5.5",
        workspace_pvc="pyspark-jobs-workspace",
        runner_service_account="pyspark-jobs-runner",
        node_selector_key="poc.local/workload",
        node_selector_value="kubeflow",
        max_upload_bytes=1024,
        require_user_header=True,
    )


def test_spark_application_is_namespace_bound(cfg: Settings) -> None:
    custom = FakeCustomApi()
    spark = SparkJobsClient(cfg, custom, FakeCoreApi())
    spark.submit_job(
        name="Daily_ETL",
        relative_file="daily-123/job.py",
        arguments='--date "2026-07-22"',
        driver_cores=1,
        driver_memory="1g",
        executor_cores=2,
        executor_memory="2g",
        executor_instances=3,
        submitted_by="user@example.com",
    )

    resource = custom.created
    assert resource["metadata"]["namespace"] == "profile-a"
    assert resource["metadata"]["name"] == "daily-etl"
    assert resource["spec"]["mainApplicationFile"] == (
        "local:///opt/spark/jobs/daily-123/job.py"
    )
    assert resource["spec"]["arguments"] == ["--date", "2026-07-22"]
    assert resource["spec"]["executor"]["instances"] == 3
    assert resource["spec"]["driver"]["serviceAccount"] == "pyspark-jobs-runner"
    assert resource["spec"]["driver"]["annotations"] == {
        "sidecar.istio.io/inject": "false"
    }
    assert resource["spec"]["sparkConf"][
        (
            "spark.kubernetes.driver.volumes."
            "persistentVolumeClaim.jobs.options.claimName"
        )
    ] == "pyspark-jobs-workspace"


def test_logs_delete_and_spark_ui_are_derived_from_job(cfg: Settings) -> None:
    custom = FakeCustomApi()
    spark = SparkJobsClient(cfg, custom, FakeCoreApi())

    assert spark.driver_logs("demo") == "profile-a/demo-driver: log"
    assert spark.spark_ui_service("demo") == "demo-ui-svc"
    assert spark.delete_job("demo") == "demo-123/demo.py"
    assert custom.deleted == "demo"


def test_upload_rejects_non_python_file(cfg: Settings) -> None:
    class FakeJobs:
        def list_jobs(self):
            return []

    main.settings.cache_clear()
    main.jobs_client.cache_clear()
    main.app.dependency_overrides[main.settings] = lambda: cfg
    main.app.dependency_overrides[main.jobs_client] = lambda: FakeJobs()
    client = TestClient(main.app)
    response = client.post(
        "/jobs",
        headers={"kubeflow-userid": "user@example.com"},
        data={"name": "demo"},
        files={"file": ("job.txt", b"print('no')", "text/plain")},
    )
    main.app.dependency_overrides.clear()
    assert response.status_code == 400
    assert response.json()["detail"] == "Only .py files are accepted."


def test_profile_resources_are_isolated() -> None:
    resources = profile_resources("team-a", "pyspark-jobs:test")
    deployment = next(item for item in resources if item["kind"] == "Deployment")
    route = next(item for item in resources if item["kind"] == "VirtualService")

    assert all(item["metadata"]["namespace"] == "team-a" for item in resources)
    assert deployment["spec"]["template"]["spec"]["serviceAccountName"] == (
        "pyspark-jobs-ui"
    )
    assert route["spec"]["http"][0]["match"][0]["uri"]["prefix"] == (
        "/pyspark-jobs/team-a/"
    )
    assert "team-a.svc.cluster.local" in (
        route["spec"]["http"][0]["route"][0]["destination"]["host"]
    )


def test_names_and_storage_paths_are_sanitized(tmp_path: Path) -> None:
    assert dns_name("  My ETL_v2 ") == "my-etl-v2"
    with pytest.raises(ValueError):
        dns_name("../../")
    with pytest.raises(ValueError):
        safe_job_directory(tmp_path, "../outside/job.py")


def test_spark_ui_redirect_stays_inside_profile_route(monkeypatch) -> None:
    monkeypatch.setenv("PROFILE_NAMESPACE", "profile-a")
    main.settings.cache_clear()
    location = main.proxy_location(
        "demo",
        "http://demo-ui-svc.profile-a.svc.cluster.local:4040/jobs/?page=1",
    )
    assert location == (
        "/pyspark-jobs/profile-a/jobs/demo/spark-ui/jobs/?page=1"
    )
    main.settings.cache_clear()
