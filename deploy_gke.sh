#!/usr/bin/env bash
set -euo pipefail

# Deploy script for bartek-adk-agent to GKE with runtime env injection.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# Deployment settings
APP_NAME="bartek-adk-agent"
AGENT_IMAGE_TAG="0.0.6"

GKE_NAMESPACE="${GKE_NAMESPACE:?Missing GKE_NAMESPACE}"
GKE_CLUSTER_PROJECT="${GKE_CLUSTER_PROJECT:?Missing GKE_CLUSTER_PROJECT}"
GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:?Missing GKE_CLUSTER_NAME}"
GKE_CLUSTER_REGION="${GKE_CLUSTER_REGION:?Missing GKE_CLUSTER_REGION}"

AGENT_IMAGE_REPO="${AGENT_IMAGE_REPO:?Missing AGENT_IMAGE_REPO}"
AGENT_IMAGE_URI="${AGENT_IMAGE_REPO}:${AGENT_IMAGE_TAG}"

GKE_SERVICE_ACCOUNT="${GKE_SERVICE_ACCOUNT:?Missing GKE_SERVICE_ACCOUNT}"
# Derive the K8s SA name (part before '@') from the full GCP SA email
GKE_SERVICE_ACCOUNT_NAME="${GKE_SERVICE_ACCOUNT%%@*}"

# Export for envsubst (deployment.yaml uses ${AGENT_IMAGE_URI} and ${GKE_SERVICE_ACCOUNT_NAME},
# service.yaml and virtual-service.yaml use ${GKE_NAMESPACE},
# virtual-service.yaml uses ${GKE_CLUSTER_REGION} and ${GKE_HTTP_URL_DOMAIN})
export AGENT_IMAGE_URI="$AGENT_IMAGE_URI"
export GKE_SERVICE_ACCOUNT_NAME="$GKE_SERVICE_ACCOUNT_NAME"
export GKE_NAMESPACE="$GKE_NAMESPACE"
export GKE_CLUSTER_REGION="$GKE_CLUSTER_REGION"
export GKE_HTTP_URL_DOMAIN="${GKE_HTTP_URL_DOMAIN:?Missing GKE_HTTP_URL_DOMAIN}"

GOOGLE_GENAI_USE_VERTEXAI="TRUE"
# SERVE_MODE: "adk" (default) for ADK dev UI, "a2a" for A2A JSONRPC server
SERVE_MODE="${SERVE_MODE:-adk}"
# A2A_AGENT_MODULE: which agent module to serve in A2A mode
A2A_AGENT_MODULE="${A2A_AGENT_MODULE:-my_upgrade_agent.agent}"

# Health-check path differs per mode:
#   adk → "/" (web UI root)
#   a2a → "/.well-known/agent.json" (A2A Agent Card; GET / returns 405 in JSONRPC mode)
if [[ "$SERVE_MODE" == "a2a" ]]; then
  HEALTH_CHECK_PATH="/.well-known/agent.json"
else
  HEALTH_CHECK_PATH="/"
fi
export SERVE_MODE A2A_AGENT_MODULE HEALTH_CHECK_PATH

required_commands=(gcloud kubectl docker)
for cmd in "${required_commands[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

# --- Ensure the GCP service account has the required IAM roles ---
# The ADK ENTRYPOINT uses --otel_to_cloud which exports OpenTelemetry traces/logs
# to Cloud Logging and Cloud Trace. This requires:
#   - roles/logging.logWriter   (logging.logEntries.create)
#   - roles/cloudtrace.agent    (cloudtrace.traces.patch)
echo "Ensuring GCP GKE SA has logging IAM role"
echo "+ gcloud projects add-iam-policy-binding $GOOGLE_CLOUD_PROJECT --member=serviceAccount:$GKE_SERVICE_ACCOUNT --role=roles/logging.logWriter"


# BigQuery Data Editor - Access to edit all the contents of datasets, otherwise: ERROR - bigquery_agent_analytics_plugin.py:2159 - Error checking for table project-id.bartek_adk_agent_analytics.agent_events: 403 GET https://bigquery.googleapis.com/bigquery/v2/projects/project-id/datasets/bartek_adk_agent_analytics/tables/agent_events?prettyPrint=false: Access Denied: Table project-id:bartek_adk_agent_analytics.agent_events: Permission bigquery.tables.get denied on table project-id:bartek_adk_agent_analytics.agent_events (or it may not exist).
gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
    --member="serviceAccount:$GKE_SERVICE_ACCOUNT" \
    --role="roles/bigquery.dataEditor" \
    --quiet

# bq add-iam-policy-binding \
# >   --member="serviceAccount:${GKE_SERVICE_ACCOUNT}" \
# >   --role="roles/bigquery.dataEditor" \
# >   project-id:bartek_adk_agent_analytics
# BigQuery error in add-iam-policy-binding operation: This feature requires allowlisting.

# BigQuery Job User - Access to run jobs, otherwise: ERROR - bigquery_agent_analytics_plugin.py:2316 - Failed to create view v_user_message_received: 403 POST https://bigquery.googleapis.com/bigquery/v2/projects/project-id/jobs?prettyPrint=false: Access Denied: Project project-id: User does not have bigquery.jobs.create permission in project project-id
gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
    --member="serviceAccount:$GKE_SERVICE_ACCOUNT" \
    --role="roles/bigquery.jobUser" \
    --quiet

# Logs Writer - Access to write logs, otherwise: Error received: Permission \'logging.logEntries.create\' denied on resource (or it may not exist)
gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
  --member="serviceAccount:$GKE_SERVICE_ACCOUNT" \
  --role="roles/logging.logWriter" \
  --quiet

# Vertex AI User - Grants access to use all resource in Vertex AI, otherwise: google.genai.errors.ClientError: 403 PERMISSION_DENIED. {'error': {'code': 403, 'message': "Permission 'aiplatform.endpoints.predict' denied on resource '//aiplatform.googleapis.com/projects/project-id/locations/us-central1/publishers/google/models/gemini-2.5-pro'
gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
    --member="serviceAccount:$GKE_SERVICE_ACCOUNT" \
    --role="roles/aiplatform.user" \
    --quiet

# Skipped as better is roles/cloudtrace.agent with fewer permissions than telemetry.writer
# Cloud Telemetry Writer - Full access to write all telemetry data, otherwise: Failed to export span batch code: 403, reason: MPermission 'telemetry.traces.write' denied on resource (or it may not exist)
#gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
#    --member="serviceAccount:$GKE_SERVICE_ACCOUNT" \
#    --role="roles/telemetry.writer" \
#    --quiet

# Cloud Trace Agent  - For service accounts. Provides ability to write traces by sending the data to Stackdriver Trace, includes telemetry.traces.write and cloudtrace.traces.patch, otherwise: Failed to export span batch code: 403, reason: MPermission 'telemetry.traces.write' denied on resource (or it may not exist)
gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
    --member="serviceAccount:$GKE_SERVICE_ACCOUNT" \
    --role="roles/cloudtrace.agent" \
    --quiet

# Final check - list the roles the SA has to confirm
gcloud projects get-iam-policy "$GOOGLE_CLOUD_PROJECT" \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:$GKE_SERVICE_ACCOUNT" \
    --format="table(bindings.role)"


required_runtime_vars=(GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION BIG_QUERY_DATASET_ID GCS_BUCKET)
for var_name in "${required_runtime_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: $var_name" >&2
    echo "Export it before running this script." >&2
    exit 1
  fi
done

if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q .; then
  echo "No active gcloud account. Run: gcloud auth login" >&2
  exit 1
fi


echo "Fetching GKE credentials: $GKE_CLUSTER_NAME ($GKE_CLUSTER_REGION / $GKE_CLUSTER_PROJECT)"
echo "+ gcloud container clusters get-credentials $GKE_CLUSTER_NAME --region $GKE_CLUSTER_REGION --project $GKE_CLUSTER_PROJECT"
gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" --region "$GKE_CLUSTER_REGION" --project "$GKE_CLUSTER_PROJECT"

echo "Building image with docker"
echo "+ docker build --build-arg GOOGLE_GENAI_USE_VERTEXAI=$GOOGLE_GENAI_USE_VERTEXAI -t $APP_NAME ."
docker build --build-arg GOOGLE_GENAI_USE_VERTEXAI="$GOOGLE_GENAI_USE_VERTEXAI" -t "$APP_NAME" .

echo "Tagging and pushing image: $AGENT_IMAGE_URI"
echo "+ docker tag $APP_NAME $AGENT_IMAGE_URI"
docker tag "$APP_NAME" "$AGENT_IMAGE_URI"
echo "+ docker push $AGENT_IMAGE_URI"
docker push "$AGENT_IMAGE_URI"

#echo "Ensuring namespace exists: $GKE_NAMESPACE"
#kubectl create namespace "$GKE_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "Applying Kubernetes manifests"
echo "+ envsubst < k8s/deployment.yaml | kubectl apply -n $GKE_NAMESPACE -f -"
envsubst < k8s/deployment.yaml | kubectl apply -n "$GKE_NAMESPACE" -f -
echo "+ envsubst < k8s/service.yaml | kubectl apply -n $GKE_NAMESPACE -f -"
envsubst < k8s/service.yaml | kubectl apply -n "$GKE_NAMESPACE" -f -
echo "+ envsubst < k8s/virtual-service.yaml | kubectl apply -n $GKE_NAMESPACE -f -"
envsubst < k8s/virtual-service.yaml | kubectl apply -n "$GKE_NAMESPACE" -f -

echo "Updating deployment runtime environment values"
echo "+ kubectl set env deployment/$APP_NAME -n $GKE_NAMESPACE GOOGLE_CLOUD_PROJECT=$GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION=$GOOGLE_CLOUD_LOCATION BIG_QUERY_DATASET_ID=$BIG_QUERY_DATASET_ID GCS_BUCKET=$GCS_BUCKET SERVE_MODE=$SERVE_MODE A2A_AGENT_MODULE=$A2A_AGENT_MODULE"
kubectl set env deployment/"$APP_NAME" -n "$GKE_NAMESPACE" \
  GOOGLE_CLOUD_PROJECT="$GOOGLE_CLOUD_PROJECT" \
  GOOGLE_CLOUD_LOCATION="$GOOGLE_CLOUD_LOCATION" \
  BIG_QUERY_DATASET_ID="$BIG_QUERY_DATASET_ID" \
  GCS_BUCKET="$GCS_BUCKET" \
  SERVE_MODE="$SERVE_MODE" \
  A2A_AGENT_MODULE="$A2A_AGENT_MODULE"

echo "Restarting deployment to pick up latest image and config"
echo "+ kubectl rollout restart deployment/$APP_NAME -n $GKE_NAMESPACE"
kubectl rollout restart deployment/"$APP_NAME" -n "$GKE_NAMESPACE"

echo "Waiting for rollout"
echo "+ kubectl rollout status deployment/$APP_NAME -n $GKE_NAMESPACE"
kubectl rollout status deployment/"$APP_NAME" -n "$GKE_NAMESPACE"

echo "Deployment complete. Current pods:"
echo "+ kubectl get pods -n $GKE_NAMESPACE -l app=$APP_NAME"
kubectl get pods -n "$GKE_NAMESPACE" -l app="$APP_NAME"

echo "App deployment url: https://${APP_NAME}-${GKE_NAMESPACE}.apps.dev-03.${GKE_CLUSTER_REGION}.dev.${GKE_HTTP_URL_DOMAIN}"
