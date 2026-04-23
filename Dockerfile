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
#   adk  (default) — unified FastAPI runtime via get_fast_api_app(...)
#   a2a             — standalone A2A JSONRPC server for agent-to-agent communication
# APP_PORT controls which port the server listens on (default: 8000).
# A2A_AGENT_MODULE selects which agent module to serve in A2A mode.
# Accepts folder name only (e.g. my_multi_agent). The ".agent" suffix
# is appended automatically by a2a_server.py at runtime.
# FASTAPI_APP_MODULE points to a module-level `app` object served by uvicorn.
# A2A enables integrated A2A mode for the FastAPI runtime when SERVE_MODE=adk.
# In integrated mode we generate <A2A_AGENT_MODULE>/agent.json at startup.
# TRACE_TO_CLOUD (true/1) enables Cloud Trace export for the unified FastAPI
# runtime. OTEL_TO_CLOUD remains available for standalone A2A runtime parity.
ENV SERVE_MODE=adk
ENV APP_PORT=8000
ENV FASTAPI_APP_MODULE=adk_fastapi_server:app
ENV A2A=false
ENV A2A_AGENT_MODULE=my_multi_agent
ENV A2A_CARD_PATH_PREFIX=/a2a

CMD if [ "$SERVE_MODE" = "a2a" ]; then \
      exec uvicorn a2a_server:app --host 0.0.0.0 --port "${PORT:-$APP_PORT}"; \
    else \
      if [ "$A2A" = "1" ] || [ "$A2A" = "true" ] || [ "$A2A" = "TRUE" ] || [ "$A2A" = "True" ] || [ "$A2A" = "yes" ] || [ "$A2A" = "YES" ] || [ "$A2A" = "Yes" ] || [ "$A2A" = "on" ] || [ "$A2A" = "ON" ] || [ "$A2A" = "On" ]; then \
        python3 prepare_adk_web_a2a_agent_card.py; \
      fi; \
      exec uvicorn "$FASTAPI_APP_MODULE" --host 0.0.0.0 --port "${PORT:-$APP_PORT}"; \
    fi
