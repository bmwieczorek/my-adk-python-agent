# Added --platform=linux/amd64 required because base image is x86_64 only;
# Without it, Podman on ARM Macs generates inconsistent layer hashes, breaking caching.
FROM --platform=linux/amd64 python:3.12-slim

WORKDIR /app

ARG GOOGLE_GENAI_USE_VERTEXAI=TRUE

ENV PYTHONUNBUFFERED=1 \
	GOOGLE_GENAI_USE_VERTEXAI=${GOOGLE_GENAI_USE_VERTEXAI}

# Suppress google-adk A2A experimental warnings in production logs.
ENV ADK_SUPPRESS_A2A_EXPERIMENTAL_FEATURE_WARNINGS=1

# --- Dependency caching layer ---
# This layer is cached as long as requirements-docker.txt does not change — pip install is skipped on subsequent builds when only source code changes.
COPY --chmod=775 requirements-docker.txt .
RUN pip install --no-cache-dir -r requirements-docker.txt

# --- Application code layer ---
# This layer is rebuilt on every code change, but pip install above is cached.
EXPOSE 8000 8001
COPY --chmod=775 . .

# SERVE_MODE selects the runtime entrypoint:
#   adk  (default) — standard ADK dev UI served by `adk web`
#   a2a             — A2A JSONRPC server for agent-to-agent communication
# APP_PORT controls which port the server listens on (default: 8000).
# A2A_AGENT_MODULE selects which agent module to serve in A2A mode.
# Accepts folder name only (e.g. my_multi_agent). The ".agent" suffix
# is appended automatically by a2a_server.py at runtime.
# OTEL_TO_CLOUD (true/1) enables Cloud Trace + Cloud Logging export for the
# a2a container, mirroring the --otel_to_cloud flag used by the adk container.
# Both containers must set this to emit OTel signals to the same GCP backends.
ENV SERVE_MODE=adk
ENV APP_PORT=8000
ENV A2A_AGENT_MODULE=my_multi_agent

CMD if [ "$SERVE_MODE" = "a2a" ]; then \
      exec uvicorn a2a_server:app --host 0.0.0.0 --port "$APP_PORT"; \
    else \
      exec adk web --host 0.0.0.0 --port "$APP_PORT" --no-reload --otel_to_cloud .; \
    fi
