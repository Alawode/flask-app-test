#!/bin/bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PROJECT_ID="project-63a74e6c-25e7-48cd-a51"
PROJECT_NUMBER="47481804387"
REGION="us-central1"
CLUSTER_NAME="flask-cluster"
REPO_NAME="flask-repo"
IMAGE_NAME="flask-app"
IMAGE_URL="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$IMAGE_NAME:latest"
# ─────────────────────────────────────────────────────────────────────────────

echo "==> Setting GCP project..."
gcloud config set project "$PROJECT_ID"

echo "==> Enabling required APIs..."
gcloud services enable container.googleapis.com artifactregistry.googleapis.com

echo "==> Creating Artifact Registry repo (if not exists)..."
if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" &>/dev/null; then
  gcloud artifacts repositories create "$REPO_NAME" \
    --repository-format=docker \
    --location="$REGION"
else
  echo "    Repo already exists, skipping."
fi

echo "==> Granting GKE node access to Artifact Registry..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader" \
  --condition=None \
  --quiet

echo "==> Building image for linux/amd64..."
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet
docker build --platform linux/amd64 -t "$IMAGE_URL" .

echo "==> Pushing image to Artifact Registry..."
docker push "$IMAGE_URL"

echo "==> Creating GKE Autopilot cluster (if not exists)..."
if ! gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" &>/dev/null; then
  gcloud container clusters create-auto "$CLUSTER_NAME" --region="$REGION"
else
  echo "    Cluster already exists, skipping."
fi

echo "==> Fetching cluster credentials..."
gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION"

echo "==> Deploying to Kubernetes..."
kubectl apply -f k8s/
kubectl rollout restart deployment/flask-app
kubectl rollout status deployment/flask-app

echo ""
echo "==> Done. External IP:"
kubectl get svc flask-app-svc --no-headers | awk '{print $4}'
