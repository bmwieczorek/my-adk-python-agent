#!/usr/bin/env bash
set -euo pipefail

# Deploy bartek-adk-agent to Cloud Run using a GCR/Artifact Registry image.
# Similar flow to deploy_gke.sh:
#   1) validate env + IAM roles
#   2) build/tag/push image
#   3) deploy service with runtime env vars

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="bartek-adk-agent"
CLOUD_RUN_SERVICE_NAME="${CLOUD_RUN_SERVICE_NAME:-$APP_NAME}"
SERVE_MODE="${SERVE_MODE:-adk}" # adk | a2a
OTEL_TO_CLOUD="${OTEL_TO_CLOUD:-true}"
TRACE_TO_CLOUD="${TRACE_TO_CLOUD:-$OTEL_TO_CLOUD}"
A2A="${A2A:-false}"
A2A_CARD_PATH_PREFIX="${A2A_CARD_PATH_PREFIX:-/a2a}"
A2A_CARD_BASE_URL="${A2A_CARD_BASE_URL:-}"
FASTAPI_APP_MODULE="${FASTAPI_APP_MODULE:-adk_fastapi_server:app}"
ADK_DISABLE_LOCAL_STORAGE="${ADK_DISABLE_LOCAL_STORAGE:-}"
MEMORY_SERVICE_URI="${MEMORY_SERVICE_URI:-}"
SESSION_SERVICE_URI="${SESSION_SERVICE_URI:-}"
BQ_ANALYTICS_PLUGIN_ENABLE="${BQ_ANALYTICS_PLUGIN_ENABLE:-}"

required_commands=(gcloud docker)
for cmd in "${required_commands[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_path_prefix() {
  local value="${1:-/a2a}"
  value="/${value#/}"
  value="${value%/}"
  if [[ -z "$value" ]]; then
    value="/a2a"
  fi
  echo "$value"
}

GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:?Must set GOOGLE_CLOUD_PROJECT}"
GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:?Must set GOOGLE_CLOUD_LOCATION}"
BIG_QUERY_DATASET_ID="${BIG_QUERY_DATASET_ID:?Must set BIG_QUERY_DATASET_ID}"
GCS_BUCKET="${GCS_BUCKET:?Must set GCS_BUCKET}"

GCR_REPOSITORY="${GCR_REPOSITORY:?Must set GCR_REPOSITORY. Examples: gcr.io/<project> or us-central1-docker.pkg.dev/<project>/<repo>/<path>}"
AGENT_IMAGE_REPO="${AGENT_IMAGE_REPO:-${GCR_REPOSITORY}/${APP_NAME}}"

if [[ ! "$AGENT_IMAGE_REPO" =~ ^(gcr\.io|[a-z0-9-]+\.gcr\.io|[a-z0-9-]+-docker\.pkg\.dev)/ ]]; then
  echo "AGENT_IMAGE_REPO must point to GCR or Artifact Registry." >&2
  echo "Accepted hosts: gcr.io, *.gcr.io, *-docker.pkg.dev" >&2
  echo "Current value: $AGENT_IMAGE_REPO" >&2
  exit 1
fi

CLOUD_RUN_SERVICE_ACCOUNT="${CLOUD_RUN_SERVICE_ACCOUNT:-bartek-adk-agent@${GOOGLE_CLOUD_PROJECT}.iam.gserviceaccount.com}"
CLOUD_RUN_REGION="${CLOUD_RUN_REGION:-$GOOGLE_CLOUD_LOCATION}"

CLOUD_RUN_NETWORK="${CLOUD_RUN_NETWORK:?Must set CLOUD_RUN_NETWORK}"
CLOUD_RUN_SUBNET="${CLOUD_RUN_SUBNET:?Must set CLOUD_RUN_SUBNET}"
CLOUD_RUN_VPC_EGRESS="${CLOUD_RUN_VPC_EGRESS:-private-ranges-only}"
CLOUD_RUN_NETWORK_TAGS="${CLOUD_RUN_NETWORK_TAGS:-}"

CLOUD_RUN_PORT="${CLOUD_RUN_PORT:-8080}"
CLOUD_RUN_CPU="${CLOUD_RUN_CPU:-1}"
CLOUD_RUN_MEMORY="${CLOUD_RUN_MEMORY:-1Gi}"
CLOUD_RUN_TIMEOUT_SECONDS="${CLOUD_RUN_TIMEOUT_SECONDS:-300}"
CLOUD_RUN_CONCURRENCY="${CLOUD_RUN_CONCURRENCY:-10}"
CLOUD_RUN_MIN_INSTANCES="${CLOUD_RUN_MIN_INSTANCES:-0}"
CLOUD_RUN_MAX_INSTANCES="${CLOUD_RUN_MAX_INSTANCES:-5}"
CLOUD_RUN_INGRESS="${CLOUD_RUN_INGRESS:-all}"
CLOUD_RUN_ALLOW_UNAUTHENTICATED="${CLOUD_RUN_ALLOW_UNAUTHENTICATED:-true}"

if [[ "$SERVE_MODE" != "adk" && "$SERVE_MODE" != "a2a" ]]; then
  echo "SERVE_MODE must be one of: adk, a2a" >&2
  exit 1
fi

ADK_WEB_A2A_ENABLED=false
if [[ "$SERVE_MODE" == "adk" ]] && is_truthy "$A2A"; then
  ADK_WEB_A2A_ENABLED=true
  A2A_CARD_PATH_PREFIX="$(normalize_path_prefix "$A2A_CARD_PATH_PREFIX")"
fi
if [[ "$SERVE_MODE" == "a2a" ]] && is_truthy "$A2A"; then
  echo "Note: A2A=true is ignored when SERVE_MODE=a2a (standalone A2A server)." >&2
fi

A2A_AGENT_MODULE="${A2A_AGENT_MODULE:-my_multi_agent}"

if [[ "$SERVE_MODE" == "a2a" || "$ADK_WEB_A2A_ENABLED" == "true" ]]; then
  if [[ ! -f "${A2A_AGENT_MODULE}/agent.py" ]]; then
    echo "A2A_AGENT_MODULE must point to an agent folder with agent.py: ${A2A_AGENT_MODULE}" >&2
    exit 1
  fi
fi

if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q .; then
  echo "No active gcloud account. Run: gcloud auth login" >&2
  exit 1
fi

# Create Cloud Run runtime SA if missing.
if [[ ! "$CLOUD_RUN_SERVICE_ACCOUNT" =~ ^([a-z][a-z0-9-]{4,28}[a-z0-9])@([a-z0-9-]+)\.iam\.gserviceaccount\.com$ ]]; then
  echo "Invalid CLOUD_RUN_SERVICE_ACCOUNT format: $CLOUD_RUN_SERVICE_ACCOUNT" >&2
  echo "Expected format: <sa-name>@<project>.iam.gserviceaccount.com" >&2
  exit 1
fi
CLOUD_RUN_SA_ACCOUNT_ID="${BASH_REMATCH[1]}"
CLOUD_RUN_SA_PROJECT="${BASH_REMATCH[2]}"

if ! gcloud iam service-accounts describe "$CLOUD_RUN_SERVICE_ACCOUNT" \
  --project "$CLOUD_RUN_SA_PROJECT" >/dev/null 2>&1; then
  if [[ "$CLOUD_RUN_SA_PROJECT" != "$GOOGLE_CLOUD_PROJECT" ]]; then
    echo "Service account ${CLOUD_RUN_SERVICE_ACCOUNT} does not exist." >&2
    echo "Auto-create is only supported when SA project matches GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT}." >&2
    exit 1
  fi

  echo "Creating service account: ${CLOUD_RUN_SERVICE_ACCOUNT}"
  gcloud iam service-accounts create "$CLOUD_RUN_SA_ACCOUNT_ID" \
    --project "$GOOGLE_CLOUD_PROJECT" \
    --display-name "Bartek ADK Agent runtime"
fi

# IAM propagation for newly created service accounts can be eventually consistent.
sa_ready=false
for _ in {1..20}; do
  if gcloud iam service-accounts describe "$CLOUD_RUN_SERVICE_ACCOUNT" \
    --project "$CLOUD_RUN_SA_PROJECT" >/dev/null 2>&1; then
    sa_ready=true
    break
  fi
  sleep 3
done
if [[ "$sa_ready" != "true" ]]; then
  echo "Service account not visible yet: $CLOUD_RUN_SERVICE_ACCOUNT" >&2
  echo "Please retry in a minute." >&2
  exit 1
fi

echo "Ensuring Cloud Run runtime SA has required IAM roles"
for role in \
  roles/aiplatform.user \
  roles/bigquery.dataEditor \
  roles/bigquery.jobUser \
  roles/cloudtrace.agent \
  roles/logging.logWriter \
  roles/monitoring.metricWriter
do
  bound=false
  for _ in {1..5}; do
    if gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
      --member="serviceAccount:$CLOUD_RUN_SERVICE_ACCOUNT" \
      --role="$role" \
      --quiet >/dev/null; then
      bound=true
      break
    fi
    sleep 3
  done
  if [[ "$bound" != "true" ]]; then
    echo "Failed to bind role $role to $CLOUD_RUN_SERVICE_ACCOUNT" >&2
    exit 1
  fi
done

# NOTE: roles/monitoring.metricWriter is intentionally assigned as the last role.
# Re-check if this role is truly required for your telemetry setup and remove if not needed.

echo "Runtime SA roles:"
gcloud projects get-iam-policy "$GOOGLE_CLOUD_PROJECT" \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:$CLOUD_RUN_SERVICE_ACCOUNT" \
  --format="table(bindings.role)"

# Auto-detect current image tag from deployed Cloud Run service and bump patch.
if [[ -n "${1:-}" ]]; then
  AGENT_IMAGE_TAG="$1"
  echo "Using explicit image tag: ${AGENT_IMAGE_TAG}"
else
  CURRENT_IMAGE="$(gcloud run services describe "$CLOUD_RUN_SERVICE_NAME" \
    --project "$GOOGLE_CLOUD_PROJECT" \
    --region "$CLOUD_RUN_REGION" \
    --format='value(spec.template.spec.containers[0].image)' 2>/dev/null || true)"
  CURRENT_TAG="$(echo "$CURRENT_IMAGE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' || true)"

  if [[ -n "$CURRENT_TAG" ]]; then
    MAJOR="${CURRENT_TAG%%.*}"
    REST="${CURRENT_TAG#*.}"
    MINOR="${REST%%.*}"
    PATCH="${REST#*.}"
    AGENT_IMAGE_TAG="${MAJOR}.${MINOR}.$((PATCH + 1))"
    echo "Current deployed tag: ${CURRENT_TAG} → bumping to: ${AGENT_IMAGE_TAG}"
  else
    AGENT_IMAGE_TAG="0.0.1"
    echo "No existing Cloud Run service image tag found. Using initial tag: ${AGENT_IMAGE_TAG}"
  fi
fi

AGENT_IMAGE_URI="${AGENT_IMAGE_REPO}:${AGENT_IMAGE_TAG}"
GOOGLE_GENAI_USE_VERTEXAI="TRUE"

REGISTRY_HOST="${AGENT_IMAGE_REPO%%/*}"
echo "Configuring Docker auth for registry host: ${REGISTRY_HOST}"
gcloud auth configure-docker "$REGISTRY_HOST" --quiet

echo "Building image with docker"
echo "+ docker build --build-arg GOOGLE_GENAI_USE_VERTEXAI=$GOOGLE_GENAI_USE_VERTEXAI -t $APP_NAME ."
docker build --build-arg GOOGLE_GENAI_USE_VERTEXAI="$GOOGLE_GENAI_USE_VERTEXAI" -t "$APP_NAME" .

echo "Tagging and pushing image: $AGENT_IMAGE_URI"
echo "+ docker tag $APP_NAME $AGENT_IMAGE_URI"
docker tag "$APP_NAME" "$AGENT_IMAGE_URI"
echo "+ docker push $AGENT_IMAGE_URI"
docker push "$AGENT_IMAGE_URI"

env_vars=(
  "GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT}"
  "GOOGLE_CLOUD_LOCATION=${GOOGLE_CLOUD_LOCATION}"
  "BIG_QUERY_DATASET_ID=${BIG_QUERY_DATASET_ID}"
  "GCS_BUCKET=${GCS_BUCKET}"
  "APP_PORT=${CLOUD_RUN_PORT}"
  "SERVE_MODE=${SERVE_MODE}"
  "FASTAPI_APP_MODULE=${FASTAPI_APP_MODULE}"
  "OTEL_TO_CLOUD=${OTEL_TO_CLOUD}"
  "TRACE_TO_CLOUD=${TRACE_TO_CLOUD}"
  "A2A=${A2A}"
)

if [[ -n "$ADK_DISABLE_LOCAL_STORAGE" ]]; then
  env_vars+=("ADK_DISABLE_LOCAL_STORAGE=${ADK_DISABLE_LOCAL_STORAGE}")
fi
if [[ -n "$MEMORY_SERVICE_URI" ]]; then
  env_vars+=("MEMORY_SERVICE_URI=${MEMORY_SERVICE_URI}")
fi
if [[ -n "$SESSION_SERVICE_URI" ]]; then
  env_vars+=("SESSION_SERVICE_URI=${SESSION_SERVICE_URI}")
fi
if [[ -n "$BQ_ANALYTICS_PLUGIN_ENABLE" ]]; then
  env_vars+=("BQ_ANALYTICS_PLUGIN_ENABLE=${BQ_ANALYTICS_PLUGIN_ENABLE}")
fi

if [[ "$SERVE_MODE" == "a2a" ]]; then
  env_vars+=("A2A_AGENT_MODULE=${A2A_AGENT_MODULE}")
  env_vars+=("A2A_PROTOCOL=https")
  env_vars+=("A2A_PORT=443")
elif [[ "$ADK_WEB_A2A_ENABLED" == "true" ]]; then
  env_vars+=("A2A_AGENT_MODULE=${A2A_AGENT_MODULE}")
  env_vars+=("A2A_CARD_PATH_PREFIX=${A2A_CARD_PATH_PREFIX}")
  if [[ -n "$A2A_CARD_BASE_URL" ]]; then
    env_vars+=("A2A_CARD_BASE_URL=${A2A_CARD_BASE_URL}")
  fi
fi

ENV_VARS_CSV="$(IFS=,; echo "${env_vars[*]}")"

deploy_cmd=(
  gcloud run deploy "$CLOUD_RUN_SERVICE_NAME"
  --project "$GOOGLE_CLOUD_PROJECT"
  --region "$CLOUD_RUN_REGION"
  --platform managed
  --image "$AGENT_IMAGE_URI"
  --service-account "$CLOUD_RUN_SERVICE_ACCOUNT"
  --execution-environment gen2
  --port "$CLOUD_RUN_PORT"
  --cpu "$CLOUD_RUN_CPU"
  --memory "$CLOUD_RUN_MEMORY"
  --timeout "${CLOUD_RUN_TIMEOUT_SECONDS}s"
  --concurrency "$CLOUD_RUN_CONCURRENCY"
  --min-instances "$CLOUD_RUN_MIN_INSTANCES"
  --max-instances "$CLOUD_RUN_MAX_INSTANCES"
  --ingress "$CLOUD_RUN_INGRESS"
  --set-env-vars "$ENV_VARS_CSV"
  --network "$CLOUD_RUN_NETWORK"
  --subnet "$CLOUD_RUN_SUBNET"
  --vpc-egress "$CLOUD_RUN_VPC_EGRESS"
)

if [[ "${CLOUD_RUN_ALLOW_UNAUTHENTICATED}" == "true" ]]; then
  deploy_cmd+=(--allow-unauthenticated)
else
  deploy_cmd+=(--no-allow-unauthenticated)
fi

if [[ -n "$CLOUD_RUN_NETWORK_TAGS" ]]; then
  deploy_cmd+=(--network-tags "$CLOUD_RUN_NETWORK_TAGS")
fi

echo "Deploying to Cloud Run"
echo "+ ${deploy_cmd[*]}"
"${deploy_cmd[@]}"

SERVICE_URL="$(gcloud run services describe "$CLOUD_RUN_SERVICE_NAME" \
  --project "$GOOGLE_CLOUD_PROJECT" \
  --region "$CLOUD_RUN_REGION" \
  --format='value(status.url)')"

if [[ "$SERVE_MODE" == "a2a" ]]; then
  A2A_HOST="${SERVICE_URL#https://}"
  A2A_HOST="${A2A_HOST#http://}"
  echo "Updating A2A_HOST in Cloud Run env to: ${A2A_HOST}"
  gcloud run services update "$CLOUD_RUN_SERVICE_NAME" \
    --project "$GOOGLE_CLOUD_PROJECT" \
    --region "$CLOUD_RUN_REGION" \
    --update-env-vars "A2A_HOST=${A2A_HOST},A2A_PROTOCOL=https,A2A_PORT=443"
elif [[ "$ADK_WEB_A2A_ENABLED" == "true" ]]; then
  echo "Updating A2A_CARD_BASE_URL in Cloud Run env to: ${SERVICE_URL}"
  gcloud run services update "$CLOUD_RUN_SERVICE_NAME" \
    --project "$GOOGLE_CLOUD_PROJECT" \
    --region "$CLOUD_RUN_REGION" \
    --update-env-vars "A2A=true,A2A_AGENT_MODULE=${A2A_AGENT_MODULE},A2A_CARD_BASE_URL=${SERVICE_URL},A2A_CARD_PATH_PREFIX=${A2A_CARD_PATH_PREFIX}"
fi

if [[ "$SERVE_MODE" == "a2a" ]]; then
  A2A_ENDPOINT_URL="${SERVICE_URL}"
  A2A_CARD_URL="${SERVICE_URL}/.well-known/agent-card.json"
  MODE_LABEL="a2a (standalone to_a2a server)"
elif [[ "$ADK_WEB_A2A_ENABLED" == "true" ]]; then
  A2A_ENDPOINT_URL="${SERVICE_URL}${A2A_CARD_PATH_PREFIX}/${A2A_AGENT_MODULE}"
  A2A_CARD_URL="${A2A_ENDPOINT_URL}/.well-known/agent-card.json"
  MODE_LABEL="adk (integrated FastAPI A2A)"
else
  A2A_ENDPOINT_URL="${SERVICE_URL}"
  A2A_CARD_URL="${SERVICE_URL}/.well-known/agent-card.json"
  MODE_LABEL="adk"
fi

echo ""
echo "Deployment complete."
echo "Image: ${AGENT_IMAGE_URI}"
echo "Mode: ${MODE_LABEL}"
echo "Service URL: ${SERVICE_URL}"
echo "A2A Endpoint URL: ${A2A_ENDPOINT_URL}"
echo "A2A Agent Card URL: ${A2A_CARD_URL}"
if [[ "$SERVE_MODE" != "a2a" && "$ADK_WEB_A2A_ENABLED" != "true" ]]; then
  echo "Note: A2A endpoint is active only when SERVE_MODE=a2a or A2A=true with SERVE_MODE=adk."
fi
