from dataclasses import dataclass
import os
from pathlib import Path


def _as_bool(value: str) -> bool:
    return value.lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    namespace: str
    jobs_root: Path
    base_path: str
    spark_image: str
    spark_version: str
    workspace_pvc: str
    runner_service_account: str
    node_selector_key: str
    node_selector_value: str
    max_upload_bytes: int
    require_user_header: bool

    @classmethod
    def from_env(cls) -> "Settings":
        namespace = os.environ.get("PROFILE_NAMESPACE", "default")
        return cls(
            namespace=namespace,
            jobs_root=Path(os.environ.get("JOBS_ROOT", "/jobs")),
            base_path=os.environ.get(
                "BASE_PATH", f"/pyspark-jobs/{namespace}"
            ).rstrip("/"),
            spark_image=os.environ.get("SPARK_IMAGE", "apache/spark:3.5.5"),
            spark_version=os.environ.get("SPARK_VERSION", "3.5.5"),
            workspace_pvc=os.environ.get(
                "WORKSPACE_PVC", "pyspark-jobs-workspace"
            ),
            runner_service_account=os.environ.get(
                "SPARK_RUNNER_SERVICE_ACCOUNT", "pyspark-jobs-runner"
            ),
            node_selector_key=os.environ.get(
                "SPARK_NODE_SELECTOR_KEY", "poc.local/workload"
            ),
            node_selector_value=os.environ.get(
                "SPARK_NODE_SELECTOR_VALUE", "kubeflow"
            ),
            max_upload_bytes=int(
                os.environ.get("MAX_UPLOAD_BYTES", str(1024 * 1024))
            ),
            require_user_header=_as_bool(
                os.environ.get("REQUIRE_USER_HEADER", "true")
            ),
        )
