#!/bin/bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PROJECT_ID="project-63a74e6c-25e7-48cd-a51"
PROJECT_NUMBER="47481804387"
SA_NAME="github-actions"
SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
KEY_FILE="key.json"
# ─────────────────────────────────────────────────────────────────────────────

echo "==> Setting GCP project..."
gcloud config set project "$PROJECT_ID"

echo "==> Creating service account for GitHub Actions..."
if ! gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null; then
  gcloud iam service-accounts create "$SA_NAME" --display-name="GitHub Actions"
else
  echo "    Service account already exists, skipping."
fi

echo "==> Granting Artifact Registry write access to GitHub Actions SA..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/artifactregistry.writer" \
  --condition=None \
  --quiet

echo "==> Granting GKE deploy access to GitHub Actions SA..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/container.developer" \
  --condition=None \
  --quiet

echo "==> Granting GKE node access to Artifact Registry (for image pulls)..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader" \
  --condition=None \
  --quiet

echo "==> Downloading service account key..."
gcloud iam service-accounts keys create "$KEY_FILE" --iam-account="$SA_EMAIL"

echo "==> Adding GCP_SA_KEY secret to GitHub..."
gh secret set GCP_SA_KEY < "$KEY_FILE"

echo "==> Deleting local key file..."
rm "$KEY_FILE"

echo ""
echo "==> Auth setup complete. GitHub Actions is ready to deploy."
