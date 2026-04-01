#!/usr/bin/env bash
set -euo pipefail

# Run bartek-adk-agent locally with Docker.
# Mounts Application Default Credentials so the container can call Vertex AI,
# BigQuery, Cloud Trace, etc. as your local identity.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# --- Settings ---
APP_NAME="bartek-adk-agent"
HOST_PORT="${HOST_PORT:-8000}"
CONTAINER_PORT=8000

# --- Required env vars (same as GKE runtime vars) ---
required_vars=(GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION BIG_QUERY_DATASET_ID GCS_BUCKET)
for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: $var_name" >&2
    echo "Export it before running this script." >&2
    exit 1
  fi
done

# --- Application Default Credentials ---
ADC_PATH="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}"
if [[ ! -f "$ADC_PATH" ]]; then
  echo "ADC file not found at $ADC_PATH" >&2
  echo "Run: gcloud auth application-default login" >&2
  exit 1
fi

# --- Build ---
echo "Building image: $APP_NAME"
echo "+ docker build -t $APP_NAME ."
docker build -t "$APP_NAME" .
docker image prune -f

# --- Run ---
echo "Starting container: $APP_NAME on port $HOST_PORT"
echo "+ docker run --name $APP_NAME --rm -it -p $HOST_PORT:$CONTAINER_PORT ..."
(docker rm -f "$APP_NAME" 2>/dev/null || true)
docker run --name "$APP_NAME" --rm -it \
  -p "${HOST_PORT}:${CONTAINER_PORT}" \
  -e GOOGLE_CLOUD_PROJECT="$GOOGLE_CLOUD_PROJECT" \
  -e GOOGLE_CLOUD_LOCATION="$GOOGLE_CLOUD_LOCATION" \
  -e BIG_QUERY_DATASET_ID="$BIG_QUERY_DATASET_ID" \
  -e GCS_BUCKET="$GCS_BUCKET" \
  -e GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json \
  -v "${ADC_PATH}:/tmp/adc.json:ro" \
  "$APP_NAME"



