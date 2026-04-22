#!/usr/bin/env bash
set -euo pipefail

# Deploy script for bartek-adk-agent to GKE with runtime env injection.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# Deployment settings
APP_NAME="bartek-adk-agent"

# Validate required commands before any command usage.
required_commands=(gcloud kubectl docker)
for cmd in "${required_commands[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

GKE_NAMESPACE="${GKE_NAMESPACE:?Must set GKE_NAMESPACE}"

GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:?Must set GOOGLE_CLOUD_PROJECT}"
GKE_CLUSTER_PROJECT="${GKE_CLUSTER_PROJECT:?Must set GKE_CLUSTER_PROJECT}"
GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:?Must set GKE_CLUSTER_NAME}"
GKE_CLUSTER_REGION="${GKE_CLUSTER_REGION:?Must set GKE_CLUSTER_REGION}"

AGENT_IMAGE_REPO="${AGENT_IMAGE_REPO:?Must set AGENT_IMAGE_REPO (e.g. registry.example.com/org/image-name)}"

GKE_SERVICE_ACCOUNT="${GKE_SERVICE_ACCOUNT:?Must set GKE_SERVICE_ACCOUNT (full GCP SA email)}"
# Derive the K8s SA name (part before '@') from the full GCP SA email
GKE_SERVICE_ACCOUNT_NAME="${GKE_SERVICE_ACCOUNT%%@*}"

GKE_HTTP_URL_DOMAIN="${GKE_HTTP_URL_DOMAIN:?Must set GKE_HTTP_URL_DOMAIN (e.g. dev.example.com)}"
GKE_CLUSTER_SUBDOMAIN_INFIX="${GKE_CLUSTER_SUBDOMAIN_INFIX:?Must set GKE_CLUSTER_SUBDOMAIN_INFIX (e.g. apps.cluster-name)}"

if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q .; then
  echo "No active gcloud account. Run: gcloud auth login" >&2
  exit 1
fi

echo "Fetching GKE credentials: $GKE_CLUSTER_NAME ($GKE_CLUSTER_REGION / $GKE_CLUSTER_PROJECT)"
echo "+ gcloud container clusters get-credentials $GKE_CLUSTER_NAME --region $GKE_CLUSTER_REGION --project $GKE_CLUSTER_PROJECT"
gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" --region "$GKE_CLUSTER_REGION" --project "$GKE_CLUSTER_PROJECT"

# Auto-detect current image tag from the running pod and bump patch version.
# If a tag is passed as $1, use that instead.
if [[ -n "${1:-}" ]]; then
  AGENT_IMAGE_TAG="$1"
  echo "Using explicit image tag: ${AGENT_IMAGE_TAG}"
else
  CURRENT_TAG=$(kubectl get deployment "$APP_NAME" -n "$GKE_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' || echo "")
  if [[ -n "$CURRENT_TAG" ]]; then
    # Bump the patch version: 0.0.7 → 0.0.8
    MAJOR="${CURRENT_TAG%%.*}"
    REST="${CURRENT_TAG#*.}"
    MINOR="${REST%%.*}"
    PATCH="${REST#*.}"
    AGENT_IMAGE_TAG="${MAJOR}.${MINOR}.$((PATCH + 1))"
    echo "Current deployed tag: ${CURRENT_TAG} → bumping to: ${AGENT_IMAGE_TAG}"
  else
    AGENT_IMAGE_TAG="0.0.1"
    echo "No existing deployment found. Using initial tag: ${AGENT_IMAGE_TAG}"
  fi
fi

AGENT_IMAGE_URI="${AGENT_IMAGE_REPO}:${AGENT_IMAGE_TAG}"

# Export for envsubst (deployment.yaml uses ${AGENT_IMAGE_URI}, ${GKE_SERVICE_ACCOUNT_NAME},
# ${A2A_AGENT_MODULE}, ${GKE_CLUSTER_SUBDOMAIN_INFIX}; service.yaml and
# virtual-service.yaml use ${GKE_NAMESPACE}; virtual-service.yaml also uses
# ${GKE_CLUSTER_REGION}, ${GKE_HTTP_URL_DOMAIN}, ${GKE_CLUSTER_SUBDOMAIN_INFIX})
export AGENT_IMAGE_URI="$AGENT_IMAGE_URI"
export GKE_SERVICE_ACCOUNT_NAME="$GKE_SERVICE_ACCOUNT_NAME"
export GKE_NAMESPACE="$GKE_NAMESPACE"
export GKE_CLUSTER_REGION="$GKE_CLUSTER_REGION"
export GKE_HTTP_URL_DOMAIN="$GKE_HTTP_URL_DOMAIN"
export GKE_CLUSTER_SUBDOMAIN_INFIX="$GKE_CLUSTER_SUBDOMAIN_INFIX"

GOOGLE_GENAI_USE_VERTEXAI="TRUE"

# --- A2A agent module selection ---
# A2A_AGENT_MODULE accepts a folder name only (e.g. my_upgrade_agent).
# The ".agent" suffix is appended automatically by a2a_server.py at runtime.
# If not set, scan the repo and let the user pick interactively.
if [[ -z "${A2A_AGENT_MODULE:-}" ]]; then
  echo ""
  echo "Scanning for available root agents..."
  AGENT_FOLDERS=()
  while IFS= read -r file; do
    # Extract folder name: ./my_upgrade_agent/agent.py → my_upgrade_agent
    folder="${file#./}"
    folder="${folder%%/*}"
    AGENT_FOLDERS+=("$folder")
  done < <(grep -rl '^root_agent\s*=' --include='agent.py' . | sort)

  if [[ ${#AGENT_FOLDERS[@]} -eq 0 ]]; then
    echo "No root_agent definitions found in the repo." >&2
    exit 1
  fi

  echo ""
  printf "%-12s %-40s\n" "Option #" "Agent folder"
  printf "%-12s %-40s\n" "--------" "----------------------------------------"
  for i in "${!AGENT_FOLDERS[@]}"; do
    printf "%-12s %-40s\n" "$((i + 1))" "${AGENT_FOLDERS[$i]}"
  done
  echo ""
  read -rp "Select the agent to expose via A2A (Option #): " selection

  if ! [[ "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#AGENT_FOLDERS[@]} )); then
    echo "Invalid selection: $selection" >&2
    exit 1
  fi
  A2A_AGENT_MODULE="${AGENT_FOLDERS[$((selection - 1))]}"
  echo "Selected: ${A2A_AGENT_MODULE}"
  echo ""
fi
export A2A_AGENT_MODULE

# --- Ensure the GCP service account has the required IAM roles ---
# Both containers export OpenTelemetry signals:
#   - adk-web: via --otel_to_cloud  (Cloud Trace + Cloud Logging)
#   - a2a:     via OTEL_TO_CLOUD=true (Cloud Trace + Cloud Logging)
# Required roles:
#   - roles/logging.logWriter   (logging.logEntries.create)
#   - roles/cloudtrace.agent    (cloudtrace.traces.patch + telemetry.traces.write)
echo "Ensuring GCP GKE SA has required IAM roles"

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


required_runtime_vars=(GOOGLE_CLOUD_LOCATION BIG_QUERY_DATASET_ID GCS_BUCKET)
for var_name in "${required_runtime_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: $var_name" >&2
    echo "Export it before running this script." >&2
    exit 1
  fi
done

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
# Runtime vars are set on both containers (adk-web and a2a share the same GCP config)
for container in adk-web a2a; do
  echo "+ kubectl set env deployment/$APP_NAME -n $GKE_NAMESPACE -c $container GOOGLE_CLOUD_PROJECT=$GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION=$GOOGLE_CLOUD_LOCATION BIG_QUERY_DATASET_ID=$BIG_QUERY_DATASET_ID GCS_BUCKET=$GCS_BUCKET"
  kubectl set env deployment/"$APP_NAME" -n "$GKE_NAMESPACE" -c "$container" \
    GOOGLE_CLOUD_PROJECT="$GOOGLE_CLOUD_PROJECT" \
    GOOGLE_CLOUD_LOCATION="$GOOGLE_CLOUD_LOCATION" \
    BIG_QUERY_DATASET_ID="$BIG_QUERY_DATASET_ID" \
    GCS_BUCKET="$GCS_BUCKET"
done

echo "Restarting deployment to pick up latest image and config"
echo "+ kubectl rollout restart deployment/$APP_NAME -n $GKE_NAMESPACE"
kubectl rollout restart deployment/"$APP_NAME" -n "$GKE_NAMESPACE"

echo "Waiting for rollout"
echo "+ kubectl rollout status deployment/$APP_NAME -n $GKE_NAMESPACE"
kubectl rollout status deployment/"$APP_NAME" -n "$GKE_NAMESPACE"

echo "Deployment complete. Current pods:"
echo "+ kubectl get pods -n $GKE_NAMESPACE -l app=$APP_NAME"
kubectl get pods -n "$GKE_NAMESPACE" -l app="$APP_NAME"

echo "ADK Web UI:  https://${APP_NAME}-${GKE_NAMESPACE}.${GKE_CLUSTER_SUBDOMAIN_INFIX}.${GKE_CLUSTER_REGION}.${GKE_HTTP_URL_DOMAIN}"
echo "A2A Server:  https://${APP_NAME}-a2a-${GKE_NAMESPACE}.${GKE_CLUSTER_SUBDOMAIN_INFIX}.${GKE_CLUSTER_REGION}.${GKE_HTTP_URL_DOMAIN}"
