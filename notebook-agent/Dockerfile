# Kubeflow-compatible JupyterLab image with a native agentic coding UI.
ARG BASE_IMAGE=ghcr.io/kubeflow/kubeflow/notebook-servers/jupyter-pytorch-full:v1.11.0
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=1.18.4

LABEL org.opencontainers.image.title="Kubeflow Jupyter AI Notebook" \
      org.opencontainers.image.description="Jupyter AI 3 + OpenCode ACP agent for notebook-native coding"

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates openjdk-17-jre-headless \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Jupyter AI discovers OpenCode automatically through its ACP client.
# Node lives in the same conda environment as Jupyter to keep PATH predictable.
RUN mamba install -y -n base -c conda-forge "nodejs>=22,<23" \
 && mamba clean --all -f -y \
 && npm install --global "opencode-ai@${OPENCODE_VERSION}" \
 && npm cache clean --force

COPY requirements.txt /tmp/agent-requirements.txt
# jupyter-server-documents 0.2.5 replaces Jupyter Server's gateway-aware
# kernel, websocket, and session managers. Keep its document services loaded,
# but let Jupyter Server select its native Enterprise Gateway-compatible stack.
RUN python -m pip install --no-cache-dir -r /tmp/agent-requirements.txt \
 && python - <<'PY'
from pathlib import Path

path = Path("/opt/conda/lib/python3.12/site-packages/jupyter_server_documents/app.py")
source = path.read_text()
overrides = (
    '        c.ServerApp.kernel_websocket_connection_class = "jupyter_server_documents.kernels.websocket_connection.NextGenKernelWebsocketConnection"\n'
    '        c.ServerApp.kernel_manager_class = "jupyter_server_documents.kernels.multi_kernel_manager.NextGenMappingKernelManager"\n'
    '        c.MultiKernelManager.kernel_manager_class = "jupyter_server_documents.kernels.kernel_manager.NextGenKernelManager"\n'
    '        c.ServerApp.session_manager_class = "jupyter_server_documents.session_manager.YDocSessionManager"\n'
)
if overrides not in source:
    raise RuntimeError("Expected jupyter-server-documents 0.2.5 kernel overrides were not found")
path.write_text(source.replace(overrides, ""))
PY
RUN rm -f /tmp/agent-requirements.txt \
 && chown -R "${NB_UID}:100" "/home/${NB_USER}"

# Verify the prebuilt frontend and server extensions during image creation.
RUN jupyter labextension list \
 && jupyter server extension list \
 && opencode --version

USER ${NB_UID}
WORKDIR /home/${NB_USER}
