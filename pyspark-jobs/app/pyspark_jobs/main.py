from __future__ import annotations

from functools import lru_cache
from pathlib import Path
import re
import shutil
import uuid
from urllib.parse import urlsplit

import httpx
from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    Header,
    HTTPException,
    Request,
    UploadFile,
)
from fastapi.responses import HTMLResponse, PlainTextResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from kubernetes.client import ApiException

from .config import Settings
from .kube import SparkJobsClient, dns_name, safe_job_directory


APP_ROOT = Path(__file__).resolve().parent.parent
MEMORY_PATTERN = re.compile(r"^[1-9][0-9]*[mg]$", re.IGNORECASE)

app = FastAPI(title="Kubeflow PySpark Jobs", docs_url=None, redoc_url=None)
app.mount("/static", StaticFiles(directory=APP_ROOT / "static"), name="static")
templates = Jinja2Templates(directory=APP_ROOT / "templates")


@lru_cache
def settings() -> Settings:
    return Settings.from_env()


@lru_cache
def jobs_client() -> SparkJobsClient:
    return SparkJobsClient(settings())


def authenticated_user(
    kubeflow_userid: str | None = Header(default=None),
) -> str:
    cfg = settings()
    if cfg.require_user_header and not kubeflow_userid:
        raise HTTPException(status_code=401, detail="Kubeflow identity is required.")
    return kubeflow_userid or "local-development"


def template_context(request: Request, **values: object) -> dict[str, object]:
    return {
        "request": request,
        "base_path": settings().base_path,
        "namespace": settings().namespace,
        **values,
    }


def proxy_location(name: str, location: str) -> str:
    parsed = urlsplit(location)
    path = parsed.path if parsed.path.startswith("/") else f"/{parsed.path}"
    query = f"?{parsed.query}" if parsed.query else ""
    fragment = f"#{parsed.fragment}" if parsed.fragment else ""
    return (
        f"{settings().base_path}/jobs/{dns_name(name)}/spark-ui"
        f"{path}{query}{fragment}"
    )


@app.get("/healthz", response_class=PlainTextResponse)
def healthz() -> str:
    return "ok"


@app.get("/", response_class=HTMLResponse)
def index(
    request: Request,
    user: str = Depends(authenticated_user),
    client_: SparkJobsClient = Depends(jobs_client),
) -> HTMLResponse:
    try:
        jobs = client_.list_jobs()
    except ApiException as error:
        raise HTTPException(status_code=502, detail=error.reason) from error
    return templates.TemplateResponse(
        request,
        "index.html",
        template_context(request, jobs=jobs, user=user),
    )


@app.post("/jobs")
async def create_job(
    request: Request,
    name: str = Form(...),
    arguments: str = Form(""),
    driver_cores: int = Form(1),
    driver_memory: str = Form("512m"),
    executor_cores: int = Form(1),
    executor_memory: str = Form("512m"),
    executor_instances: int = Form(1),
    file: UploadFile = File(...),
    user: str = Depends(authenticated_user),
    client_: SparkJobsClient = Depends(jobs_client),
) -> RedirectResponse:
    cfg = settings()
    job_name = dns_name(name)
    if not file.filename or Path(file.filename).suffix.lower() != ".py":
        raise HTTPException(status_code=400, detail="Only .py files are accepted.")
    if not 1 <= driver_cores <= 4 or not 1 <= executor_cores <= 4:
        raise HTTPException(status_code=400, detail="CPU cores must be between 1 and 4.")
    if not 1 <= executor_instances <= 10:
        raise HTTPException(
            status_code=400, detail="Executor instances must be between 1 and 10."
        )
    if not MEMORY_PATTERN.fullmatch(driver_memory) or not MEMORY_PATTERN.fullmatch(
        executor_memory
    ):
        raise HTTPException(
            status_code=400,
            detail="Memory must use Spark notation such as 512m or 1g.",
        )

    safe_filename = re.sub(r"[^A-Za-z0-9_.-]", "_", Path(file.filename).name)
    relative_dir = f"{job_name}-{uuid.uuid4().hex[:8]}"
    relative_file = f"{relative_dir}/{safe_filename}"
    job_dir = cfg.jobs_root / relative_dir
    job_dir.mkdir(parents=True, exist_ok=False)
    target = job_dir / safe_filename
    size = 0
    try:
        with target.open("wb") as output:
            while chunk := await file.read(64 * 1024):
                size += len(chunk)
                if size > cfg.max_upload_bytes:
                    raise HTTPException(
                        status_code=413,
                        detail=f"Upload exceeds {cfg.max_upload_bytes} bytes.",
                    )
                output.write(chunk)
        if size == 0:
            raise HTTPException(status_code=400, detail="Uploaded file is empty.")

        client_.submit_job(
            name=job_name,
            relative_file=relative_file,
            arguments=arguments,
            driver_cores=driver_cores,
            driver_memory=driver_memory,
            executor_cores=executor_cores,
            executor_memory=executor_memory,
            executor_instances=executor_instances,
            submitted_by=user,
        )
    except Exception:
        shutil.rmtree(job_dir, ignore_errors=True)
        raise
    finally:
        await file.close()

    return RedirectResponse(
        url=f"{cfg.base_path}/jobs/{job_name}",
        status_code=303,
    )


@app.get("/jobs/{name}", response_class=HTMLResponse)
def job_detail(
    name: str,
    request: Request,
    user: str = Depends(authenticated_user),
    client_: SparkJobsClient = Depends(jobs_client),
) -> HTMLResponse:
    try:
        summary = client_.get_summary(name)
        events = client_.events(name)
    except ApiException as error:
        if error.status == 404:
            raise HTTPException(status_code=404, detail="Job not found.") from error
        raise HTTPException(status_code=502, detail=error.reason) from error
    return templates.TemplateResponse(
        request,
        "detail.html",
        template_context(
            request,
            job=summary,
            events=events,
            user=user,
        ),
    )


@app.get("/jobs/{name}/logs", response_class=PlainTextResponse)
def job_logs(
    name: str,
    _: str = Depends(authenticated_user),
    client_: SparkJobsClient = Depends(jobs_client),
) -> str:
    try:
        return client_.driver_logs(name)
    except ApiException as error:
        if error.status == 404:
            raise HTTPException(status_code=404, detail="Driver log not found.") from error
        raise HTTPException(status_code=502, detail=error.reason) from error


@app.post("/jobs/{name}/delete")
def delete_job(
    name: str,
    _: str = Depends(authenticated_user),
    client_: SparkJobsClient = Depends(jobs_client),
) -> RedirectResponse:
    cfg = settings()
    try:
        relative_file = client_.delete_job(name)
        if relative_file:
            shutil.rmtree(
                safe_job_directory(cfg.jobs_root, relative_file),
                ignore_errors=True,
            )
    except ApiException as error:
        if error.status != 404:
            raise HTTPException(status_code=502, detail=error.reason) from error
    return RedirectResponse(url=f"{cfg.base_path}/", status_code=303)


@app.api_route(
    "/jobs/{name}/spark-ui/{path:path}",
    methods=["GET", "POST"],
)
async def spark_ui_proxy(
    name: str,
    path: str,
    request: Request,
    _: str = Depends(authenticated_user),
    client_: SparkJobsClient = Depends(jobs_client),
) -> Response:
    try:
        service = client_.spark_ui_service(name)
    except (ApiException, ValueError) as error:
        raise HTTPException(status_code=404, detail=str(error)) from error

    target = (
        f"http://{service}.{settings().namespace}.svc.cluster.local:4040/{path}"
    )
    body = await request.body()
    headers = {
        key: value
        for key, value in request.headers.items()
        if key.lower() not in {"host", "content-length", "connection"}
    }
    async with httpx.AsyncClient(follow_redirects=False, timeout=30) as proxy:
        upstream = await proxy.request(
            request.method,
            target,
            params=request.query_params,
            content=body,
            headers=headers,
        )
    response_headers = {
        key: value
        for key, value in upstream.headers.items()
        if key.lower()
        not in {
            "content-encoding",
            "content-length",
            "transfer-encoding",
            "connection",
        }
    }
    if location := upstream.headers.get("location"):
        response_headers["location"] = proxy_location(name, location)
    return Response(
        content=upstream.content,
        status_code=upstream.status_code,
        headers=response_headers,
        media_type=upstream.headers.get("content-type"),
    )
