# Kubeflow, Jupyter AI, and PySpark Architecture

This document explains how Kubeflow, JupyterLab, Jupyter AI, OpenCode,
Jupyter Enterprise Gateway, and Spark Operator fit together in this POC.

## Core design

Kubeflow does not provide the coding agent itself. Kubeflow provides an
authenticated, namespaced Kubernetes environment for running JupyterLab
containers. The AI integration is delivered through a custom
Kubeflow-compatible Notebook image.

```text
Kubeflow Notebook
  └── JupyterLab
      ├── Jupyter AI Chat UI
      ├── OpenCode ACP agent
      ├── Jupyter MCP tools
      ├── Java 17 + PySpark 3.5.5
      └── Jupyter Server
          └── Enterprise Gateway
              └── Python or Spark kernels
```

The responsibilities are divided as follows:

```text
Kubeflow manages the Notebook container
Jupyter AI manages the chat interface
OpenCode performs coding tasks
Jupyter MCP exposes Notebook and file tools
Enterprise Gateway manages remote kernels
Spark Operator manages Spark driver and executor pods
```

## 1. Browser access and authentication

The [Kubeflow Central Dashboard][kubeflow-dashboard] provides the authenticated
entry point to Kubeflow components.

```text
Browser
  → localhost:8081
  → kubectl port-forward
  → Istio Ingress Gateway
  → OAuth2 Proxy and Dex authentication
  → Kubeflow Central Dashboard
  → Notebook route
  → JupyterLab pod
```

Istio routes the Notebook under a namespace-specific URL:

```text
/notebook/kubeflow-user-example-com/test-spark/
```

The authenticated identity is propagated through the `kubeflow-userid`
header. Kubeflow Profiles determine which namespaces that identity can access.
A Profile wraps a Kubernetes Namespace and configures its RBAC and Istio
authorization. See [Profiles and Namespaces][kubeflow-profiles].

For this local POC, the Istio gateway is exposed using the port-forwarding
method described in the [Kubeflow dashboard access documentation][dashboard-access].

## 2. Notebook lifecycle

Creating a Notebook through the Kubeflow UI creates a `Notebook` custom
resource:

```yaml
apiVersion: kubeflow.org/v1
kind: Notebook
metadata:
  name: test-spark
  namespace: kubeflow-user-example-com
spec:
  template:
    spec:
      containers:
        - name: test-spark
          image: ramneekk/kubeflow-notebook-ai-pyspark:latest
```

The Notebook Controller watches these resources and reconciles the required
Kubernetes workload and networking objects. In this cluster, the effective
lifecycle is:

```text
Notebook CR
  → StatefulSet
  → Notebook Pod
  → Kubernetes Service
  → Istio route
```

The Notebook CR contains a Kubernetes Pod template. It can therefore define:

- Container images
- CPU and memory resources
- Environment variables
- Service accounts
- PVC-backed volumes
- Node selectors and tolerations
- Image pull secrets

The complete schema is documented in the [Kubeflow Notebook v1 API][notebook-api].

## 3. Kubeflow custom image contract

The [Kubeflow custom image documentation][container-images] requires a
Notebook image to:

- Expose HTTP on port `8888`
- Respect the injected `NB_PREFIX`
- Permit iframe access
- Run as `jovyan` with UID `1000`
- Use `/home/jovyan` as the user home
- Start with an empty PVC mounted at `/home/jovyan`

This image extends an official Kubeflow Notebook image, which already
implements that contract:

```dockerfile
ARG BASE_IMAGE=ghcr.io/kubeflow/kubeflow/notebook-servers/jupyter-pytorch-full:v1.11.0
FROM ${BASE_IMAGE}
```

Kubeflow injects a base path similar to:

```text
NB_PREFIX=/notebook/kubeflow-user-example-com/test-spark
```

Jupyter then serves itself under that path rather than at `/`.

## 4. Components inside the image

The custom image contains four functional layers:

```text
JupyterLab
├── Jupyter AI frontend and server extensions
├── OpenCode ACP agent
├── Jupyter MCP server
└── Java 17 + PySpark 3.5.5
```

### Jupyter AI

`jupyter-ai==3.0.1` provides:

- The JupyterLab Chat interface
- AI routing
- Persona management
- The Agent Client Protocol client
- Permission prompts
- Jupyter MCP integration

These are Jupyter extensions, not Kubeflow control-plane components.
Kubeflow starts a container that already contains and enables them.

### OpenCode

OpenCode is installed as a Node-based ACP coding agent:

```dockerfile
RUN mamba install -y -n base -c conda-forge "nodejs>=22,<23" \
 && npm install --global "opencode-ai@1.18.4"
```

Jupyter AI discovers `opencode` through `PATH` and registers it as an
available persona. The OpenCode subprocess is started when a chat uses that
persona.

### Jupyter MCP

The MCP server exposes controlled operations for:

- Reading and updating Notebooks
- Reading and writing workspace files
- Executing approved commands
- Inspecting the Jupyter environment

It runs inside the Notebook container and is not exposed publicly through
Istio.

### Java and PySpark

OpenJDK 17 and PySpark 3.5.5 are installed in the image so local tests do not
need to install large dependencies while the Notebook is running.

## 5. Chat request flow

For a request such as:

```text
Create a PySpark program that tests Java and Spark.
```

the internal flow is:

```text
1. The browser writes the message into the Jupyter Chat document
2. Jupyter AI Router receives the message
3. Persona Manager forwards it to the OpenCode ACP subprocess
4. OpenCode plans the required changes
5. OpenCode requests MCP or terminal tools
6. Jupyter displays an approval request
7. The user allows or rejects the operation
8. An approved tool writes the Python file or Notebook cells
9. An approved terminal tool executes the code
10. Output returns through ACP to the Chat interface
```

The agent runs inside the Notebook container as `jovyan`; it is not an
independent privileged Kubernetes control-plane service.

## 6. Persistence

Kubeflow mounts the workspace PVC at:

```text
/home/jovyan
```

The PVC stores:

- Notebooks and Python files
- Chat documents
- Git repositories
- Jupytext files
- OpenCode authentication state
- User Jupyter configuration

Image-provided software is installed under immutable container paths such as
`/opt/conda` and `/usr/local/bin`.

```text
Pod restart      → user files remain
Image replacement → user files remain
PVC deletion     → user files are lost
```

The integration patches the existing `test-spark` Notebook image so its
existing workspace PVC remains attached.

## 7. Security boundary

The agent runs with the Notebook identity:

```text
Linux user: jovyan
UID: 1000
Kubernetes ServiceAccount: default-editor
```

Its effective permissions are constrained by:

1. Linux file permissions
2. PVC permissions
3. Notebook ServiceAccount RBAC
4. Kubeflow Profile namespace authorization
5. Jupyter AI approval prompts

Approval prompts are a user-facing safeguard. Kubernetes RBAC remains the
cluster security boundary. If the Notebook ServiceAccount cannot create a
Kubernetes resource, OpenCode cannot bypass that restriction.

No provider credentials are built into the image. OpenCode authentication is
performed from the Notebook terminal:

```bash
opencode auth login
```

## 8. Enterprise Gateway integration

Jupyter normally launches kernels inside the Notebook pod. This POC configures:

```text
JUPYTER_GATEWAY_URL=http://enterprise-gateway.enterprise-gateway:8888
```

Jupyter Server then uses its `GatewayKernelManager`. The
[Enterprise Gateway documentation][gateway-manager] explains that this
manager presents the normal kernel-management interface while forwarding
kernel operations to a remote gateway.

```text
Browser
  → Jupyter Server
  → GatewayKernelManager
  → Enterprise Gateway REST and WebSocket APIs
  → Process proxy
  → Kernel
```

The browser does not connect directly to Enterprise Gateway. Jupyter Server
proxies kernel REST and WebSocket communication.

## 9. Python kernel execution

For the `python3` kernelspec:

```text
Notebook requests python3
  → Enterprise Gateway
  → LocalProcessProxy
  → Python kernel starts in the Enterprise Gateway pod
  → Jupyter proxies the WebSocket connection
  → The Notebook receives kernel messages and results
```

This path has been verified successfully in the POC.

## 10. Intended remote Spark execution

The distributed Spark execution path is:

```text
Notebook selects spark_python_operator
  → Jupyter forwards the request to Enterprise Gateway
  → Enterprise Gateway reads the kernelspec
  → SparkOperatorProcessProxy runs launch_custom_resource.py
  → The launcher creates a SparkApplication CR
  → Spark Operator reconciles the SparkApplication
  → Spark Operator creates the driver pod
  → The driver creates executor pods
  → Kernel connection details return to Enterprise Gateway
  → Jupyter connects to the remote Spark kernel
```

Enterprise Gateway uses process proxies to represent remote kernel processes,
as described in its [system architecture documentation][gateway-architecture].

Current POC status:

- Enterprise Gateway is running
- Remote Python kernels work
- Spark Operator is installed
- `SparkApplication` resources are created
- The Spark Operator kernel does not yet complete startup

The remaining remote-Spark work includes Spark Operator CR compatibility,
driver and executor images, RBAC, storage, networking, and connection-file
delivery.

## 11. Local PySpark versus remote Spark

These are separate execution paths.

### Local PySpark

```text
OpenCode terminal command
  → Python process in the Notebook pod
  → Local Java JVM
  → Spark master local[*]
```

Local Java 17 and PySpark 3.5.5 execution has been verified.

### Remote Spark

```text
Notebook kernel request
  → Enterprise Gateway
  → SparkApplication
  → Spark driver and executor pods
```

This Enterprise Gateway kernel path still requires completion. The independent
PySpark Jobs path described below is working end to end.

## 12. Jupyter AI and Enterprise Gateway compatibility

Jupyter AI 3.0.1 installs `jupyter-server-documents 0.2.5`. That version
replaces Jupyter Server's:

- Kernel manager
- Multi-kernel manager
- WebSocket connection manager
- Session manager

Those managers assume local kernels. Enterprise Gateway's kernelspec methods
are asynchronous, which initially produced:

```text
'coroutine' object has no attribute 'metadata'
```

The image keeps the Jupyter document and chat services enabled but removes the
four manager overrides. Jupyter Server can then select its native
gateway-aware managers:

```text
Before:
Jupyter AI document manager → assumes local kernel → failure

After:
Jupyter AI document and chat services
        +
Jupyter native GatewayKernelManager → Enterprise Gateway
```

## 13. Resource behavior

The original Notebook memory limit was 1.2 GiB. Running JupyterLab, OpenCode,
dependency installation, and a local Spark JVM caused Kubernetes to terminate
the container:

```text
Reason: OOMKilled
Exit code: 137
```

The final resource configuration is:

```yaml
requests:
  cpu: "1"
  memory: 1Gi
limits:
  cpu: "2"
  memory: 3Gi
```

Remote Spark driver and executor resources are configured separately from the
Notebook pod.

## 14. PySpark Jobs dashboard integration

Kubeflow does not ship a global Spark jobs dashboard. This POC implements the
[Central Dashboard custom-menu pattern][dashboard-customize] with one
namespace-bound application instance per Profile:

```text
Central Dashboard menu: /pyspark-jobs/{ns}/
  → Istio VirtualService for that Profile
  → Profile PySpark Jobs FastAPI service
  → SparkApplication v1beta2
  → Spark Operator 2.5.1
  → apache/spark:3.5.5 driver and executor pods
```

The Spark Operator watches the explicit `enterprise-gateway` namespace plus
all namespaces matching:

```text
app.kubernetes.io/part-of=kubeflow-profile
```

This is a union: Enterprise Gateway remote-kernel resources remain visible,
while every current and future Kubeflow Profile can submit namespaced jobs.

### Profile reconciliation

A controller in `kubeflow` watches `Profile` objects and reconciles these
resources into the matching namespace:

```text
pyspark-jobs Deployment and Service
pyspark-jobs-workspace PVC
pyspark-jobs-ui and pyspark-jobs-runner ServiceAccounts
namespace-scoped Roles and RoleBindings
/pyspark-jobs/<namespace>/ VirtualService
```

The controller needs a cross-namespace ClusterRole because Kubernetes prevents
a principal from creating Roles that grant permissions it does not hold. That
elevated permission exists only in the central reconciler. Each generated UI
uses `pyspark-jobs-ui`, whose SparkApplication and log access is limited to its
own namespace. Spark pods use the separate `pyspark-jobs-runner` account.

Deleting a Profile deletes its namespace through the Kubeflow Profile
lifecycle, which removes the generated UI, RBAC, route, and PVC together.

### Submission and storage

The application accepts `.py` files up to 1 MiB, generates immutable
server-side paths, validates Spark resources, and creates a Python
`SparkApplication` using cluster mode. User-supplied text never controls a
proxy destination or filesystem parent path.

```text
Browser upload
  → /jobs/<generated-directory>/<safe-filename>.py
  → Profile local-path PVC
  → /opt/spark/jobs in driver and executors
  → local:///opt/spark/jobs/<generated-path>.py
```

Spark Operator 2.5.1 retained the v1beta2 `volumes` fields but did not copy
them into the generated Spark 3.5 driver pod in this environment. The working
implementation therefore uses Spark's native Kubernetes PVC properties:

```text
spark.kubernetes.driver.volumes.persistentVolumeClaim.jobs.*
spark.kubernetes.executor.volumes.persistentVolumeClaim.jobs.*
```

The PVC is `ReadWriteOnce` local-path storage. The UI, driver, and executors
are pinned to `poc.local/workload=kubeflow`, so they all run on the worker
that can mount it. This is appropriate for the single-worker POC, not for a
multi-node production Spark cluster.

### Status, logs, deletion, and Spark UI

The UI reads state from `status.applicationState`, events from the Kubernetes
Events API, and logs only from `status.driverInfo.podName`. Deletion uses
background Kubernetes propagation and removes the associated generated upload
directory.

Spark UI access is a constrained reverse proxy:

```text
Browser
  → /pyspark-jobs/<namespace>/jobs/<job>/spark-ui/
  → service named by status.driverInfo.webUIServiceName
  → port 4040
```

The application does not accept a host or URL from the browser. Spark's
`spark.ui.proxyBase` makes UI assets and links use the Profile route, and the
proxy rewrites the initial upstream redirect so the internal service DNS name
is never exposed to the browser. The live UI exists only while the driver and
its service are available.

Driver and executor Istio injection is disabled. They communicate inside the
Profile namespace using Spark's own protocols and do not need HTTP ingress
sidecars; disabling injection also avoids sidecar shutdown delays and excess
memory use.

### Verified behavior

The live ARM64 RKE2 cluster was validated with
`pyspark-jobs/examples/smoke.py`:

```text
Upload and submit                → HTTP 303
SparkApplication                → SUBMITTED → RUNNING → COMPLETED
Driver/executor                 → created on poc-kf-rke2-agent
Driver output                   → PYSPARK_JOBS_SMOKE_SUM=5050
Spark UI page and assets        → served through the constrained proxy
Job deletion                    → SparkApplication and upload removed
Cross-Profile ServiceAccount    → denied by Kubernetes RBAC
Temporary Profile              → provisioned automatically, removed on delete
```

## Responsibility boundaries

| Layer | Responsibility |
|---|---|
| Kubeflow Dashboard | Authenticated platform UI |
| Kubeflow Profile | Namespace ownership and user isolation |
| Notebook Controller | Notebook workload lifecycle |
| Notebook CR | Image, resources, PVC, and ServiceAccount |
| Istio | HTTP routing and authorization |
| Custom image | Jupyter AI, OpenCode, Java, and PySpark |
| Jupyter AI | Chat, personas, routing, and approvals |
| OpenCode | Agent reasoning and coding operations |
| Jupyter MCP | Notebook and workspace tools |
| Enterprise Gateway | Remote kernel lifecycle |
| Spark Operator | Spark driver and executor lifecycle |
| PySpark Jobs UI | Validated uploads and namespace-bound job management |
| PySpark Jobs controller | Per-Profile application reconciliation |
| Kubernetes | Scheduling, networking, storage, and RBAC |

Kubeflow remains responsible for securely running and exposing the Notebook
environment. AI capabilities are delivered through the custom Notebook image,
while Enterprise Gateway and Spark Operator extend where computation can run.

## References

- [Kubeflow Notebooks overview][notebooks-overview]
- [Kubeflow Notebook container images][container-images]
- [Kubeflow Notebook v1 API][notebook-api]
- [Kubeflow Central Dashboard][kubeflow-dashboard]
- [Kubeflow Profiles and Namespaces][kubeflow-profiles]
- [Customizing the Kubeflow Central Dashboard][dashboard-customize]
- [Accessing the Kubeflow Dashboard][dashboard-access]
- [Spark on Kubernetes volume configuration][spark-volumes]
- [Jupyter Enterprise Gateway kernel manager][gateway-manager]
- [Jupyter Enterprise Gateway system architecture][gateway-architecture]

[notebooks-overview]: https://www.kubeflow.org/docs/components/notebooks/overview/
[container-images]: https://www.kubeflow.org/docs/components/notebooks/container-images/
[notebook-api]: https://www.kubeflow.org/docs/components/notebooks/api-reference/notebook-v1/
[kubeflow-dashboard]: https://www.kubeflow.org/docs/components/central-dash/overview/
[kubeflow-profiles]: https://www.kubeflow.org/docs/components/central-dash/profiles/
[dashboard-customize]: https://www.kubeflow.org/docs/components/central-dash/customize/
[dashboard-access]: https://www.kubeflow.org/docs/components/central-dash/access/
[spark-volumes]: https://spark.apache.org/docs/3.5.5/running-on-kubernetes.html#using-kubernetes-volumes
[gateway-manager]: https://jupyter-enterprise-gateway.readthedocs.io/en/latest/developers/kernel-manager.html
[gateway-architecture]: https://jupyter-enterprise-gateway.readthedocs.io/en/latest/contributors/system-architecture.html
