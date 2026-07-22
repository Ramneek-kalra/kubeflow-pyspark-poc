# Kubeflow ↔ Grafana integration (technical)

This document explains how Prometheus and Grafana are wired into the ARM64
Kubeflow POC so Data Science / Data Engineering users get **Profile-scoped**
metrics from the Central Dashboard menu item **Workspace Metrics**.

It is intentionally separate from the root `README.md`, which only covers
install/open steps.

## Goals

- One shared Grafana (not one Grafana per Profile).
- Scope every panel by Kubeflow Profile namespace (`kubeflow-user-example-com`, …).
- Reuse existing Kubeflow auth (Dex + oauth2-proxy) — no second login for viewers.
- Embed Grafana inside the Central Dashboard iframe (`DASHBOARD_FORCE_IFRAME`).
- Stay light enough for Multipass + single RKE2 worker (ARM64).

## Architecture

```text
Browser
  └─ http://localhost:8081
       └─ kubectl port-forward → istio-ingressgateway (istio-system)
            │
            ├─ /          → Central Dashboard (oauth2-proxy → Dex)
            ├─ /jupyter/  → Notebooks UI
            ├─ /pyspark-jobs/{ns}/ → PySpark Jobs UI
            └─ /grafana/  → VirtualService → kps-grafana.monitoring:80
                              │
                              ├─ anonymous Viewer (default)
                              └─ Prometheus datasource
                                   ├─ kube-state-metrics  (pod/PVC inventory)
                                   └─ kubelet/cAdvisor    (CPU/memory)
```

Important design choice: the `monitoring` namespace has **Istio injection
disabled**. Prometheus scrapes kube-state-metrics and kubelet over plain HTTP;
mesh mTLS previously caused scrape `403`s. The Istio **gateway** still reaches
Grafana via VirtualService without requiring a sidecar on the Grafana pod.

## Components and files

| Piece | Location | Role |
| --- | --- | --- |
| Helm values | `kube-prometheus-values.yaml` | Lightweight `kube-prometheus-stack` (chart `75.15.1`, release `kps`) |
| Route + dashboard | `grafana-kubeflow.yaml` | ConfigMap dashboard, VirtualService `/grafana/`, AuthorizationPolicy |
| Install | `../scripts/11-install-grafana.sh` | Helm install, menu patch, rollout waits |
| Uninstall | `../scripts/12-uninstall-grafana.sh` | Remove stack + menu entry |

Chart release name / fullname override: **`kps`**  
Namespace: **`monitoring`**

Installed workloads (typical):

- `kps-grafana`
- `prometheus-kps-prometheus-0`
- `kps-kube-state-metrics`
- `kps-operator` (Prometheus Operator)

Disabled for POC size: Alertmanager, node-exporter, kube-apiserver/etcd/scheduler
scrapes, default Grafana dashboards.

## Request path (auth and routing)

1. User is already authenticated to Kubeflow through **oauth2-proxy** and **Dex**.
2. Central Dashboard menu link (per Profile):

   ```text
   /grafana/d/kubeflow-ns/ds-de-kubeflow-workspace?orgId=1&refresh=30s&var-namespace={ns}
   ```

   `{ns}` is substituted by the dashboard with the selected Profile namespace.
3. Istio `VirtualService` `grafana` (gateway `kubeflow/kubeflow-gateway`) matches
   prefix `/grafana/` and routes to
   `kps-grafana.monitoring.svc.cluster.local:80`.
4. Grafana is configured for **subpath** serving and **iframe embedding** (see
   below). Anonymous **Viewer** is enabled so the iframe does not prompt for a
   Grafana password. Optional admin: `admin` / `admin`.

`AuthorizationPolicy` in `monitoring` allows traffic from the ingress gateway
service account (and in-namespace sources). Combined with injection disabled,
this is gateway-fronted access, not full mesh authz for every scrape.

## Grafana server settings (iframe + subpath)

These live under `grafana.grafana.ini` in `kube-prometheus-values.yaml`:

```ini
[server]
domain = localhost:8081
root_url = http://localhost:8081/grafana/
serve_from_sub_path = true

[auth.anonymous]
enabled = true
org_role = Viewer

[security]
allow_embedding = true
cookie_samesite = disabled
cookie_secure = false
```

### Why these matter

| Setting | Why |
| --- | --- |
| `root_url` / `domain` with `:8081` | Browser and iframe load assets/API against the **same origin** users type. Using `http://localhost/grafana/` (no port) breaks the Central Dashboard iframe. |
| `serve_from_sub_path` | Grafana lives under `/grafana/`, not `/`. |
| `allow_embedding` + cookie flags | Required for Kubeflow’s iframe (`DASHBOARD_FORCE_IFRAME`). |
| Anonymous Viewer | Viewers stay inside Dex/oauth2-proxy; no second login for read-only dashboards. |

## Namespace scoping (not multi-tenant isolation)

This stack is **shared Grafana + PromQL filters**, not hard multi-tenancy.

- Dashboard UID: `kubeflow-ns`
- Title: **DS/DE Kubeflow Workspace**
- Template variable: `namespace` (label “Kubeflow Profile”)
- Variable query:

  ```text
  label_values(kube_pod_info{namespace=~"kubeflow-.*"}, namespace)
  ```

  with regex `/^(kubeflow-.+|.*-user-.*)$/` to keep Profile-like namespaces.

Do **not** chain `label_values(...) or label_values(...)`. Grafana’s variable
parser is not PromQL; that pattern produced:

```text
1:51: parse error: unexpected ","
```

Every panel filters with `namespace="$namespace"` (or joins on pods in that
namespace). Classification examples:

| UI section | PromQL idea |
| --- | --- |
| Notebooks | `kube_pod_info{..., created_by_kind="StatefulSet"}` + cAdvisor CPU/mem |
| PySpark / Spark | `created_by_kind="SparkApplication"` or pod name `*-driver` / `*-exec-N` |
| Pipelines | name regex for pipeline/workflow/argo (empty until Pipelines is installed) |
| Katib / TensorBoard | name regex |
| Volumes | `kube_persistentvolumeclaim_*` |

Metrics sources:

- **kube-state-metrics** → inventory, phases, PVC requests, owner refs
- **kubelet cAdvisor** → `container_cpu_usage_seconds_total`,
  `container_memory_working_set_bytes`

Retention: **6h** (POC). Scrape interval: **30s**.

## Central Dashboard menu wiring

`scripts/11-install-grafana.sh` patches ConfigMap `dashboard-config` in
`kubeflow`:

- Removes older “Grafana” / “Workspace Metrics” entries if present
- Appends **Workspace Metrics** with the `{ns}` URL above
- Restarts `deployment/dashboard` so the menu reloads

Users must select a Profile first so `{ns}` is set; otherwise the dashboard
variable may be empty.

## Install / uninstall

```bash
# from repo root
./scripts/11-install-grafana.sh
./scripts/12-uninstall-grafana.sh
```

Prerequisites: working RKE2 kubeconfig (`.state/rke2.yaml`), Helm, Kubeflow
gateway already installed, local port-forward:

```bash
kubectl -n istio-system port-forward svc/istio-ingressgateway 8081:80
```

Open: http://localhost:8081 → select Profile → **Workspace Metrics**.

## Operational notes (POC)

### Port-forward fragility

Access is via local `kubectl port-forward` to the ingress gateway. If the UI
hangs or connections refuse, the tunnel is usually wedged — restart the
port-forward. Cluster API health can still be fine while `:8081` is dead.

### Istio injection

Keep:

```bash
kubectl label namespace monitoring istio-injection=disabled --overwrite
```

Re-enabling injection without scrape TLS/auth fixes will break Prometheus
targets (especially kube-state-metrics).

### Resource placement

Workloads use `nodeSelector: poc.local/workload=kubeflow` (agent node).

### What this is not

- Not per-Profile Grafana instances or NetworkPolicy tenant isolation
- Not full cluster SRE (no node-exporter, limited kube component scrapes)
- Not a replacement for Notebooks UI **Last activity** (that comes from
  notebook-controller culling annotations — see
  `../scripts/13-enable-notebook-culling.sh`)

## Troubleshooting

| Symptom | Likely cause | Check / fix |
| --- | --- | --- |
| Blank iframe / assets fail | Wrong `root_url` (missing `:8081`) | Confirm `grafana.ini` `root_url` / `domain` |
| `parse error: unexpected ","` | Invalid Grafana variable query with `or` | Use a single `label_values(...)` |
| Panels empty but notebook running | Wrong Profile in `var-namespace`, or scrape gap | Query Prometheus for `kube_pod_info{namespace="..."}` and `container_*` |
| Prometheus targets 403 | Istio injection on `monitoring` | Disable injection; restart scrapes |
| `:8081` hangs | Stuck port-forward | Restart gateway port-forward |
| Menu missing Workspace Metrics | Dashboard ConfigMap not patched | Re-run `11-install-grafana.sh` or patch `dashboard-config` |

Quick Prometheus checks (from inside the Prometheus pod):

```bash
kubectl -n monitoring exec prometheus-kps-prometheus-0 -c prometheus -- \
  wget -qO- 'http://127.0.0.1:9090/api/v1/query?query=kube_pod_info'
```

## Extension points

- Add more dashboards as ConfigMaps labeled `grafana_dashboard=1` (sidecar
  picks them up cluster-wide via `searchNamespace: ALL`).
- Point `root_url` / `domain` at a real hostname if you stop using localhost
  port-forward.
- For stronger isolation later: separate datasources, Grafana Orgs, or
  proxy that injects namespace from the Kubeflow userid header — out of scope
  for this POC.
