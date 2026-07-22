FROM python:3.12-slim

ARG APP_UID=1000
ARG APP_GID=1000

LABEL org.opencontainers.image.title="Kubeflow PySpark Jobs" \
      org.opencontainers.image.description="Profile-isolated SparkApplication UI for Kubeflow"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

RUN groupadd --gid "${APP_GID}" app \
 && useradd --uid "${APP_UID}" --gid "${APP_GID}" --create-home app

WORKDIR /app

COPY requirements.txt /tmp/requirements.txt
RUN python -m pip install --no-cache-dir -r /tmp/requirements.txt \
 && rm -f /tmp/requirements.txt

COPY app /app
RUN chown -R app:app /app

USER app
EXPOSE 8080

CMD ["uvicorn", "pyspark_jobs.main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--forwarded-allow-ips=*"]
