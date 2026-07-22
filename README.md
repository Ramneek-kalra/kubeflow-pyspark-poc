# POC — Kubeflow on RKE2 for PySpark

An isolated local platform integrating:

1. Kubeflow Notebooks with Jupyter AI and OpenCode
2. Jupyter Enterprise Gateway for remote kernels
3. Spark Operator for Kubernetes-native PySpark applications
4. A Profile-isolated **PySpark Jobs** dashboard application

This folder does **not** reuse the existing `labs/week1-rke2` cluster.

## Pinned stack

| Component | Version |
|---|---|
| Ubuntu | 24.04 |
| RKE2 / Kubernetes | `v1.34.9+rke2r1` / `v1.34.9` |
| Kubeflow Community Distribution | `26.03.1` |
| Kustomize | `5.8.1` |
| Storage | local-path provisioner `v0.0.32` |
| CNI | RKE2 Canal |
| Spark Operator | `2.5.1` |
| Spark runtime | `apache/spark:3.5.5` |

Kubeflow 26.03.1 is the latest stable release as of July 2026. The release
requires Kubernetes 1.34 or newer.

## Architecture

```text
macOS host (16 GiB)
├── poc-kf-rke2-server (2 CPU / 4 GiB)
│   ├── RKE2 server, API server, embedded etcd
│   └── NoSchedule control-plane taint
└── poc-kf-rke2-agent (6 CPU / 10 GiB)
    ├── Kubeflow platform workloads
    ├── Notebook pods
    ├── Enterprise Gateway
    └── Spark driver/executor pods and PySpark Jobs UI
```

The default `core` profile installs:

- cert-manager, Istio, Dex, oauth2-proxy
- Central Dashboard and Profiles
- Kubeflow Notebooks v1
- Katib

It intentionally excludes Spark Operator, Jupyter Enterprise Gateway,
Pipelines, KServe/Knative, Trainer, Hub, and pre-GA Workspaces v2 from the
base Kubeflow install. Spark Operator, Enterprise Gateway, and PySpark Jobs
are installed separately so their lifecycle and resource use remain explicit.

Kubeflow Pipelines 2.16.1 is excluded from the Apple Silicon core profile
because its API server and UI images are amd64-only and currently crash under
QEMU emulation. Pipelines are not required for the target remote PySpark
kernel execution path.

Set `KUBEFLOW_PROFILE="full"` in `config.env` for the complete upstream
distribution, still with Spark Operator removed. The full profile is unlikely
to run reliably with the current host memory or ARM64 architecture.

## Host prerequisites

```bash
brew install multipass kubectl helm
```

Docker Desktop is also required to build ARM64 application images.

Allow at least 35–45 GiB of free disk while all images are present.

## 1. Create the dedicated VMs

The existing three `rke2-*` lab VMs currently reserve about 12 GiB. Stop them
while creating this POC:

```bash
cd POC-Kubeflow-PySpark
STOP_OLD_LAB_VMS=true ./scripts/01-create-vms.sh
```

The old VMs are stopped, not deleted.

## 2. Install RKE2

```bash
./scripts/02-install-rke2.sh
export KUBECONFIG="$PWD/.state/rke2.yaml"
kubectl get nodes
```

To merge the POC into the standard terminal kubeconfig and select it:

```bash
./scripts/06-configure-terminal-access.sh
# Future terminals can now run kubectl directly.
```

The server is tainted and the worker has:

```text
node-role.kubernetes.io/worker=true
poc.local/workload=kubeflow
```

## 3. Install Kubeflow

```bash
./scripts/03-install-kubeflow.sh
```

The first install can take 15–30 minutes because it pulls many ARM64 images.
The script is idempotent and can be rerun after an interrupted image pull or
webhook startup race.

## 4. Validate and access

```bash
./scripts/04-status.sh
./scripts/05-access.sh
```

Open <http://localhost:8081> (`8080` is already used by the local Temporal UI).

Development credentials from the upstream manifests:

```text
user@example.com
12341234
```

Do not use these credentials outside a local POC.

## Agentic JupyterLab notebook

Build and deploy the Jupyter AI 3 + OpenCode notebook:

```bash
./scripts/07-build-agent-notebook.sh
./scripts/08-deploy-agent-notebook.sh
```

The deployment script integrates Jupyter AI into the existing `test-spark`
user Notebook while preserving its Enterprise Gateway settings and workspace
PVC. Open **Notebooks → test-spark → Connect**, then create a Chat and mention
`@OpenCode`. Provider authentication and security notes are in
[`notebook-agent/README.md`](notebook-agent/README.md).

To populate the Notebooks UI **Last activity** column (and stop idle Notebooks
after 24h), enable culling:

```bash
./scripts/13-enable-notebook-culling.sh
```

## PySpark Jobs menu

Install the per-Profile PySpark Jobs application:

```bash
./scripts/09-install-pyspark-jobs.sh
```

The installer:

- builds and preloads the ARM64 UI/controller image into RKE2;
- removes the three stale, unprocessed Enterprise Gateway SparkApplications
  once;
- configures Spark Operator to watch `enterprise-gateway` and namespaces
  labeled `app.kubernetes.io/part-of=kubeflow-profile`;
- deploys the central Profile reconciler;
- adds **PySpark Jobs** to `dashboard-config`; and
- waits for the current Profile UI and PVC.

Open <http://localhost:8081>, choose **PySpark Jobs**, upload a `.py` file, and
set the job resources. The UI provides submission, list/status, Kubernetes
events, driver logs, deletion, and a constrained Spark UI reverse proxy.

Each Kubeflow Profile receives its own:

```text
Deployment + Service + VirtualService
1 GiB pyspark-jobs-workspace PVC
UI and Spark runner ServiceAccounts
namespace-scoped Roles and RoleBindings
```

Uploaded files are stored on the Profile PVC and mounted into drivers and
executors through Spark's native Kubernetes PVC configuration. Driver and
executor pods use `poc.local/workload=kubeflow`, which is required because
the `ReadWriteOnce` local-path volume is tied to the RKE2 worker.

Run the included smoke program through the UI:

```text
pyspark-jobs/examples/smoke.py
```

Remove only this integration, while keeping Kubeflow, Enterprise Gateway, and
Spark Operator:

```bash
./scripts/10-uninstall-pyspark-jobs.sh --yes
```

The uninstall command deletes uploaded-job PVC data and therefore requires
explicit confirmation.

## Grafana (namespace-scoped)

Install a lightweight Prometheus + Grafana stack and wire it into the Kubeflow
menu for the currently selected Profile namespace:

```bash
./scripts/11-install-grafana.sh
```

**Technical design** (auth, Istio, iframe, PromQL scoping, troubleshooting):
[`monitoring/README.md`](monitoring/README.md).

This creates:

```text
monitoring/
  Prometheus (6h retention)
  kube-state-metrics
  Grafana with "DS/DE Kubeflow Workspace" dashboard
Istio route: /grafana/
Dashboard menu: Workspace Metrics → namespace-scoped DS/DE dashboard
  Sections: Notebooks, PySpark Jobs, Pipelines/Workflows, Katib, TensorBoards, Volumes
```

Open <http://localhost:8081>, select a Profile, then click **Workspace Metrics**.
The namespace variable is filled from the active Kubeflow Profile (`{ns}`), and
panels are grouped for DS/DE use: Notebooks, PySpark Jobs, Pipelines,
Katib, TensorBoards, and Volumes.

Optional Grafana admin login: `admin` / `admin` (anonymous Viewer is enabled
behind the existing Dex/oauth2-proxy gateway).

## PySpark execution paths

The Notebook remote-kernel path is:

```text
Kubeflow Jupyter Notebook
  → Enterprise Gateway kernel request
  → Kubernetes Spark driver
  → Spark executor pods on the RKE2 agent
```

The Jobs dashboard path is independent:

```text
Kubeflow Dashboard
  → Profile PySpark Jobs UI
  → SparkApplication v1beta2
  → Spark Operator
  → Spark driver and executor pods
```

The current worker label can be used for Spark pod affinity:

```yaml
nodeSelector:
  poc.local/workload: kubeflow
```

## Operations

```bash
# Stop/start without deleting data
multipass stop poc-kf-rke2-server poc-kf-rke2-agent
multipass start poc-kf-rke2-server poc-kf-rke2-agent

# Recreate local access after restart
./scripts/05-access.sh

# Inspect Spark Operator and per-Profile Jobs resources
./scripts/04-status.sh

# Permanently remove only this POC
./scripts/99-destroy.sh --yes

# Restart the older lab VMs if needed
multipass start rke2-server rke2-agent-1 rke2-agent-2
```

## Important limitations

- Single control-plane and single worker: no HA.
- local-path storage is node-local, `ReadWriteOnce`, and unsuitable for
  production. Jobs are pinned to the worker that hosts the upload PVC.
- The Mac has limited RAM; concurrent Spark executors must have strict limits.
- RKE2 Canal enforces NetworkPolicy. A gateway compatibility policy is included.
- Access uses local port-forwarding and development credentials.
- Automatic cross-namespace Profile reconciliation requires the documented
  elevated controller ClusterRole. Each generated UI remains namespace-bound.
- The Spark UI exists only while its driver pod and service are available.
- This is a learning POC, not a production Kubeflow distribution.
