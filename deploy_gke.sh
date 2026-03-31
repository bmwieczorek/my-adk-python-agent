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
IMAGE_URI="${AGENT_IMAGE_REPO}:${AGENT_IMAGE_TAG}"

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
gcloud container clusters get-credentials "$GKE_CLUSTER_NAME" --region "$GKE_CLUSTER_REGION" --project "$GKE_CLUSTER_PROJECT"

echo "Building image with docker"
docker build --build-arg GOOGLE_GENAI_USE_VERTEXAI="$GOOGLE_GENAI_USE_VERTEXAI" -t "$APP_NAME" .

echo "Tagging and pushing image: $IMAGE_URI"
docker tag "$APP_NAME" "$IMAGE_URI"
docker push "$IMAGE_URI"

#echo "Ensuring namespace exists: $GKE_NAMESPACE"
#kubectl create namespace "$GKE_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "Applying Kubernetes manifests"
kubectl apply -f k8s/deployment.yaml -n "$GKE_NAMESPACE"
kubectl apply -f k8s/service.yaml -n "$GKE_NAMESPACE"
kubectl apply -f k8s/virtual-service.yaml -n "$GKE_NAMESPACE"

echo "Updating deployment image and runtime environment values"
kubectl set image deployment "$APP_NAME" "$APP_NAME=$IMAGE_URI" -n "$GKE_NAMESPACE"
kubectl set env deployment/"$APP_NAME" -n "$GKE_NAMESPACE" \
  GOOGLE_CLOUD_PROJECT="$GOOGLE_CLOUD_PROJECT" \
  GOOGLE_CLOUD_LOCATION="$GOOGLE_CLOUD_LOCATION" \
  BIG_QUERY_DATASET_ID="$BIG_QUERY_DATASET_ID" \
  GCS_BUCKET="$GCS_BUCKET"

echo "Waiting for rollout"
kubectl rollout status deployment/"$APP_NAME" -n "$GKE_NAMESPACE"

echo "Deployment complete. Current pods:"
kubectl get pods -n "$GKE_NAMESPACE" -l app="$APP_NAME"

