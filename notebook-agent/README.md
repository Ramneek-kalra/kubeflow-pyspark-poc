# JupyterLab-native coding agent for user Notebooks

This custom Kubeflow Notebook image contains:

- Jupyter AI `3.0.1`
- Jupyter MCP notebook tools
- OpenCode `1.18.4` as the provider-neutral ACP coding agent
- OpenJDK 17 and PySpark `3.5.5` for local smoke tests
- Jupytext and JupyterLab Git

The image extends the same Kubeflow PyTorch Full image used by `test-spark`.
The agent can edit files and notebook cells, execute cells, and run approved
terminal commands. Jupyter AI asks for permission before write/execute actions.
The existing Enterprise Gateway environment and user workspace PVC are
preserved when the image is applied.

## Build, preload, and deploy

```bash
cd POC-Kubeflow-PySpark
./scripts/07-build-agent-notebook.sh
./scripts/08-deploy-agent-notebook.sh
```

The image is imported directly into RKE2 containerd for this local POC. A
production cluster should pull an immutable digest from a private registry.
`08-deploy-agent-notebook.sh` updates the existing `test-spark` Notebook; it
does not create a separate Notebook server. It assigns 2 CPUs and a 3 GiB
memory limit so JupyterLab, OpenCode, and a local PySpark JVM can run together.

## Provider authentication

Open a terminal inside the notebook and run:

```bash
opencode auth login
```

Authentication data is stored under `/home/jovyan`, which is backed by the
workspace PVC.

No credentials are built into the image. For production, inject the selected
provider key from a Kubernetes Secret into each user's Notebook environment.

## Use

1. Open the Kubeflow dashboard.
2. Go to **Notebooks** and connect to `test-spark`.
3. In JupyterLab, select **Chat** from the launcher or sidebar.
4. Mention `@OpenCode` in the chat.
5. Approve notebook edits or commands when prompted.

Prefer Jupytext-paired `.py` files for changes that need clean Git diffs.

## Security boundary

The agent runs as `jovyan` (UID 1000), not root. It can access the mounted
workspace and the permissions of the Notebook's `default-editor`
ServiceAccount. Do not grant cluster-admin to the Notebook ServiceAccount.
