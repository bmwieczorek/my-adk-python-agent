#!/usr/bin/env bash
set -euo pipefail

# Deploy script for bartek-adk-agent to GKE with runtime env injection.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# Deployment settings
APP_NAME="bartek-adk-agent"
AGENT_IMAGE_TAG="0.0.3"

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

required_commands=(gcloud kubectl docker)
for cmd in "${required_commands[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

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
echo "+ kubectl set env deployment/$APP_NAME -n $GKE_NAMESPACE GOOGLE_CLOUD_PROJECT=$GOOGLE_CLOUD_PROJECT GOOGLE_CLOUD_LOCATION=$GOOGLE_CLOUD_LOCATION BIG_QUERY_DATASET_ID=$BIG_QUERY_DATASET_ID GCS_BUCKET=$GCS_BUCKET"
kubectl set env deployment/"$APP_NAME" -n "$GKE_NAMESPACE" \
  GOOGLE_CLOUD_PROJECT="$GOOGLE_CLOUD_PROJECT" \
  GOOGLE_CLOUD_LOCATION="$GOOGLE_CLOUD_LOCATION" \
  BIG_QUERY_DATASET_ID="$BIG_QUERY_DATASET_ID" \
  GCS_BUCKET="$GCS_BUCKET"

echo "Restarting deployment to pick up latest image and config"
echo "+ kubectl rollout restart deployment/$APP_NAME -n $GKE_NAMESPACE"
kubectl rollout restart deployment/"$APP_NAME" -n "$GKE_NAMESPACE"

echo "Waiting for rollout"
echo "+ kubectl rollout status deployment/$APP_NAME -n $GKE_NAMESPACE"
kubectl rollout status deployment/"$APP_NAME" -n "$GKE_NAMESPACE"

echo "Deployment complete. Current pods:"
echo "+ kubectl get pods -n $GKE_NAMESPACE -l app=$APP_NAME"
kubectl get pods -n "$GKE_NAMESPACE" -l app="$APP_NAME"

