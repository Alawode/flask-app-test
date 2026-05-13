# Flask App Deployment on GKE — Notes

## What We Built

A simple Flask REST API containerized with Docker, deployed to Google Kubernetes Engine (GKE) Autopilot on GCP, with a fully automated CI/CD pipeline via GitHub Actions.

**Stack:**
- Python + Flask + gunicorn
- Docker (python:3.11-slim base image)
- GKE Autopilot (us-central1)
- Artifact Registry (Docker image hosting)
- GitHub Actions (CI/CD)
- Workload Identity Federation (keyless GCP auth)

---

## Architecture

```
Internet → GCP Load Balancer (port 80)
         → K8s Service (flask-app-svc)
         → Pod replicas (port 8080)
         → gunicorn
         → Flask app
```

**CI/CD flow:**
```
git push to master
  → GitHub Actions triggered
  → Authenticates to GCP via Workload Identity (no key)
  → Builds & pushes Docker image to Artifact Registry
  → Rolls out new image to GKE
  → kubectl rollout status waits for healthy pods
```

---

## Key Decisions

### gunicorn over Flask dev server
Flask's built-in server is single-threaded and not safe for production. gunicorn handles concurrent requests and is the standard production WSGI server for Python apps.

### python:3.11-slim base image
`slim` strips unnecessary system packages, keeping the image small. Avoids the ~1GB footprint of the full Python image.

### Layer caching in Dockerfile
```dockerfile
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
```
Dependencies are installed before copying app code. Docker caches each layer — `pip install` only re-runs when `requirements.txt` changes, not on every code change. Keeps rebuilds fast.

### GKE Autopilot over Standard
Autopilot manages node provisioning, scaling, and patching automatically. No node pools to configure. Nodes are provisioned on-demand when pods are scheduled — `kubectl get nodes` returning empty before deployment is expected behaviour.

### Artifact Registry over Docker Hub
Images stay within the same GCP project, making IAM-based access control straightforward and avoiding public registry dependencies.

### 2 replicas + health probes
- 2 replicas ensure the app stays available if one pod crashes
- `readinessProbe` — prevents traffic being sent to a pod before it's ready
- `livenessProbe` — restarts a pod if it becomes unhealthy
- Both probes hit `/health` which is a lightweight endpoint with no side effects

### Workload Identity Federation over service account keys
GCP org policy blocked service account key creation. Even without that constraint, Workload Identity is the correct production approach — no long-lived credentials to store, rotate, or leak. GitHub Actions gets a short-lived token per job that GCP verifies against GitHub's OIDC provider.

---

## CI/CD Pipeline Setup

### GitHub Actions workflow (`.github/workflows/deploy.yml`)
Triggers on every push to `master`. Key steps:
1. Authenticate to GCP via Workload Identity
2. Configure Docker for Artifact Registry
3. Build and push image tagged with the git commit SHA
4. Get GKE cluster credentials
5. `kubectl set image` to update the deployment
6. `kubectl rollout status` to wait for healthy pods

Using the commit SHA as the image tag (instead of `latest`) means every deploy is traceable to an exact commit and rollbacks are easy.

### Workload Identity Federation setup
Three resources created in GCP:
1. **Workload Identity Pool** (`github-pool`) — trusts external identity providers
2. **OIDC Provider** (`github-provider`) — trusts tokens from `token.actions.githubusercontent.com`, scoped to `Alawode/flask-app-test` only
3. **IAM binding** — allows the pool to impersonate the `github-actions` service account

Required workflow permissions:
```yaml
permissions:
  contents: read
  id-token: write   # required to request OIDC token from GitHub
```

---

## Errors Encountered

### 1. ErrImagePull — wrong platform architecture

**Error:**
```
no match for platform in manifest: not found
```

**Cause:** Apple Silicon Mac builds `arm64` images by default. GKE nodes run `amd64`.

**Fix:**
```bash
docker build --platform linux/amd64 -t <image>:<tag> .
```

**How to prevent it:**
Always specify `--platform linux/amd64` for local builds targeting GKE. This is a non-issue in CI since GitHub Actions `ubuntu-latest` runners are `amd64`.

---

### 2. ErrImagePull — missing Artifact Registry permissions

**Error:**
```
Failed to pull image: rpc error: code = NotFound
```

**Cause:** The GKE node's default compute service account did not have permission to pull images from Artifact Registry.

**Fix:**
```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"
```

**How to prevent it:**
Include this in your cluster setup script. It must be re-applied every time the cluster is recreated since it binds to the compute service account, not the cluster itself.

---

### 3. gcloud virtualenv setup failure (Python/libexpat conflict)

**Error:**
```
ImportError: dlopen(pyexpat.cpython-313-darwin.so): Symbol not found: _XML_SetAllocTrackerActivationThreshold
```

**Cause:** Python 3.13 via Homebrew has a binary incompatibility with the macOS system `libexpat`.

**Impact:** Low — only affects optional binary extension modules. Core `gcloud` commands work fine.

**Fix:**
```bash
export CLOUDSDK_PYTHON=/opt/homebrew/opt/python@3.11/libexec/bin/python
echo 'export CLOUDSDK_PYTHON=/opt/homebrew/opt/python@3.11/libexec/bin/python' >> ~/.zshrc
```

---

### 4. GitHub Actions OIDC token not injected

**Error:**
```
GitHub Actions did not inject $ACTIONS_ID_TOKEN_REQUEST_TOKEN or $ACTIONS_ID_TOKEN_REQUEST_URL
```

**Cause:** The workflow was missing the `id-token: write` permission needed for Workload Identity Federation.

**Fix:** Add to the workflow:
```yaml
permissions:
  contents: read
  id-token: write
```

---

### 5. Service account key creation blocked by org policy

**Error:**
```
FAILED_PRECONDITION: Key creation is not allowed on this service account.
constraints/iam.disableServiceAccountKeyCreation
```

**Cause:** GCP org policy on new accounts disables service account key creation by default.

**Fix:** Use Workload Identity Federation instead — no keys needed. This is also the correct production approach regardless of the policy.

---

### 6. Artifact Registry repo / GKE cluster not found after teardown

**Cause:** Resources were deleted to avoid charges. The CI/CD pipeline expects them to exist.

**How to prevent it:**
Run `deploy.sh` before triggering the pipeline — it recreates the repo and cluster if they don't exist. In production, infrastructure is never torn down between deploys; this only applies to a dev/interview setup.

---

## GCP Resources

| Resource | Name | Details |
|---|---|---|
| GKE Cluster | `flask-cluster` | Autopilot, us-central1 |
| Artifact Registry | `flask-repo` | Docker format, us-central1 |
| Workload Identity Pool | `github-pool` | global |
| OIDC Provider | `github-provider` | Scoped to Alawode/flask-app-test |
| Service Account | `github-actions` | Used by CI/CD pipeline |
| K8s Deployment | `flask-app` | 2 replicas |
| K8s Service | `flask-app-svc` | LoadBalancer, port 80 → 8080 |

---

## Commands Reference

```bash
# Full deploy from scratch
./deploy.sh

# Auth setup (one-time)
./setup-auth.sh

# Build for correct platform (local only)
docker build --platform linux/amd64 -t IMAGE_URL .
docker push IMAGE_URL

# Get cluster credentials
gcloud container clusters get-credentials flask-cluster --region us-central1

# Deploy / update
kubectl apply -f k8s/
kubectl rollout restart deployment/flask-app
kubectl rollout status deployment/flask-app

# Debug pods
kubectl get pods
kubectl get svc
kubectl describe pod POD_NAME
kubectl logs POD_NAME
kubectl get events --sort-by=.lastTimestamp

# Tear down (to stop billing)
kubectl delete -f k8s/
gcloud container clusters delete flask-cluster --region us-central1
gcloud artifacts repositories delete flask-repo --location us-central1
```
