#!/usr/bin/env bash
set -euo pipefail

# Run bartek-adk-agent locally with Docker.
# Mounts Application Default Credentials so the container can call Vertex AI,
# BigQuery, Cloud Trace, etc. as your local identity.
#
# Set SERVE_MODE=a2a to start the A2A JSONRPC server instead of the ADK dev UI.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# --- Settings ---
APP_NAME="bartek-adk-agent"
HOST_PORT="${HOST_PORT:-8000}"
CONTAINER_PORT=8000
SERVE_MODE="${SERVE_MODE:-adk}"
A2A="${A2A:-false}"
A2A_AGENT_MODULE="${A2A_AGENT_MODULE:-my_multi_agent}"
A2A_CARD_PATH_PREFIX="${A2A_CARD_PATH_PREFIX:-/a2a}"
# Used only for integrated adk web A2A mode (SERVE_MODE=adk + A2A=true).
# Defaults to localhost so the generated agent card is host-reachable.
A2A_CARD_BASE_URL="${A2A_CARD_BASE_URL:-http://localhost:${HOST_PORT}}"
# Pass OTEL_TO_CLOUD through when set — mirrors --otel_to_cloud on the adk container.
OTEL_TO_CLOUD="${OTEL_TO_CLOUD:-}"

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
    *) return 1 ;;
  esac
}

ADK_WEB_A2A_ENABLED=false
if [[ "$SERVE_MODE" == "adk" ]] && is_truthy "$A2A"; then
  ADK_WEB_A2A_ENABLED=true
fi
if [[ "$SERVE_MODE" == "a2a" ]] && is_truthy "$A2A"; then
  echo "Note: A2A=true is ignored when SERVE_MODE=a2a (standalone A2A server)." >&2
fi

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
echo "Starting container: $APP_NAME on port $HOST_PORT (SERVE_MODE=$SERVE_MODE, A2A=$A2A, A2A_AGENT_MODULE=$A2A_AGENT_MODULE)"
if [[ "$ADK_WEB_A2A_ENABLED" == "true" ]]; then
  echo "Integrated adk web A2A mode enabled (expected agent card path: ${A2A_CARD_BASE_URL}${A2A_CARD_PATH_PREFIX}/${A2A_AGENT_MODULE}/.well-known/agent-card.json)"
fi
echo "+ docker run --name $APP_NAME --rm -it -p $HOST_PORT:$CONTAINER_PORT ..."
(docker rm -f "$APP_NAME" 2>/dev/null || true)
docker run --name "$APP_NAME" --rm -it \
  -p "${HOST_PORT}:${CONTAINER_PORT}" \
  -e SERVE_MODE="$SERVE_MODE" \
  -e A2A="$A2A" \
  -e A2A_AGENT_MODULE="$A2A_AGENT_MODULE" \
  -e A2A_CARD_BASE_URL="$A2A_CARD_BASE_URL" \
  -e A2A_CARD_PATH_PREFIX="$A2A_CARD_PATH_PREFIX" \
  -e OTEL_TO_CLOUD="$OTEL_TO_CLOUD" \
  -e GOOGLE_CLOUD_PROJECT="$GOOGLE_CLOUD_PROJECT" \
  -e GOOGLE_CLOUD_LOCATION="$GOOGLE_CLOUD_LOCATION" \
  -e BIG_QUERY_DATASET_ID="$BIG_QUERY_DATASET_ID" \
  -e GCS_BUCKET="$GCS_BUCKET" \
  -e GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json \
  -v "${ADC_PATH}:/tmp/adc.json:ro" \
  "$APP_NAME"
