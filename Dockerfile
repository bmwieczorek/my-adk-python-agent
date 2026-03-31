# Added --platform=linux/amd64 required because base image is x86_64 only;
# Without it, Podman on ARM Macs generates inconsistent layer hashes, breaking caching.
FROM --platform=linux/amd64 python:3.12-slim

WORKDIR /app

ARG GOOGLE_GENAI_USE_VERTEXAI=TRUE

ENV PYTHONUNBUFFERED=1 \
	GOOGLE_GENAI_USE_VERTEXAI=${GOOGLE_GENAI_USE_VERTEXAI}


# --- Dependency caching layer ---
# This layer is cached as long as requirements-docker.txt does not change — pip install is skipped on subsequent builds when only source code changes.
COPY --chmod=775 requirements-docker.txt .
RUN pip install --no-cache-dir -r requirements-docker.txt

# --- Application code layer ---
# This layer is rebuilt on every code change, but pip install above is cached.
EXPOSE 8000
COPY --chmod=775 . .

ENTRYPOINT ["adk", "web", "--host", "0.0.0.0"]
