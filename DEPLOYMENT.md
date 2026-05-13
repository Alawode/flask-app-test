# Flask App Deployment on GKE — Notes

## What We Built

A simple Flask REST API containerized with Docker and deployed to Google Kubernetes Engine (GKE) Autopilot on GCP.

**Stack:**
- Python + Flask + gunicorn
- Docker (python:3.11-slim base image)
- GKE Autopilot (us-central1)
- Artifact Registry (Docker image hosting)

---

## Architecture

```
Internet → GCP Load Balancer (port 80)
         → K8s Service (flask-app-svc)
         → Pod replicas (port 8080)
         → gunicorn
         → Flask app
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
Dependencies are copied and installed before the app code. Docker caches each layer — this means `pip install` only re-runs when `requirements.txt` changes, not on every code change. Keeps rebuilds fast.

### GKE Autopilot over Standard
Autopilot manages node provisioning, scaling, and patching automatically. No node pools to configure. Nodes are provisioned on-demand when pods are scheduled — `kubectl get nodes` returning empty before deployment is expected behaviour.

### Artifact Registry over Docker Hub
Images stay within the same GCP project, making IAM-based access control straightforward and avoiding public registry dependencies.

### 2 replicas + health probes
- 2 replicas ensure the app stays available if one pod crashes
- `readinessProbe` — prevents traffic being sent to a pod before it's ready
- `livenessProbe` — restarts a pod if it becomes unhealthy
- Both probes hit `/health` which is a lightweight endpoint with no side effects

---

## Errors Encountered

### 1. ErrImagePull — wrong platform architecture

**Error:**
```
no match for platform in manifest: not found
```

**Cause:** The Mac used for development is Apple Silicon (ARM64). Docker builds images for the host architecture by default, producing an `arm64` image. GKE nodes run `amd64` (x86_64), so they couldn't pull the image.

**Fix:**
```bash
docker build --platform linux/amd64 -t <image>:<tag> .
```

**How to prevent it:**
Always specify `--platform linux/amd64` when building images destined for GKE on Apple Silicon machines. Better long-term: add this to the CI/CD pipeline (GitHub Actions runs on `ubuntu-latest` which is `amd64` by default, so this won't be an issue there).

Optionally add to `Dockerfile` to make it explicit:
```dockerfile
FROM --platform=linux/amd64 python:3.11-slim
```

---

### 2. ErrImagePull — missing Artifact Registry permissions

**Error:**
```
Failed to pull image: rpc error: code = NotFound
```

**Cause:** The GKE node's default compute service account did not have permission to pull images from Artifact Registry.

**Fix:**
```bash
# Get project number first
gcloud projects describe PROJECT_ID --format="value(projectNumber)"

# Grant Artifact Registry reader role to the compute service account
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader"
```

**How to prevent it:**
Grant this permission before deploying — ideally as part of cluster setup. Add it to your infrastructure setup script or Terraform config so it's never missed.

---

### 3. gcloud virtualenv setup failure (Python/libexpat conflict)

**Error:**
```
ImportError: dlopen(pyexpat.cpython-313-darwin.so): Symbol not found: _XML_SetAllocTrackerActivationThreshold
```

**Cause:** Python 3.13 installed via Homebrew has a binary incompatibility with the macOS system `libexpat`. gcloud's virtualenv setup fails when trying to install modules using pip inside the venv.

**Impact:** Low — only affects optional binary extension modules (e.g. crc32c acceleration). Core `gcloud` commands work fine.

**Fix:**
```bash
# Point gcloud at Python 3.11 instead
export CLOUDSDK_PYTHON=/opt/homebrew/opt/python@3.11/libexec/bin/python

# Make permanent
echo 'export CLOUDSDK_PYTHON=/opt/homebrew/opt/python@3.11/libexec/bin/python' >> ~/.zshrc
```

---

## GCP Resources Created

| Resource | Name | Details |
|---|---|---|
| GKE Cluster | `flask-cluster` | Autopilot, us-central1 |
| Artifact Registry | `flask-repo` | Docker format, us-central1 |
| K8s Deployment | `flask-app` | 2 replicas |
| K8s Service | `flask-app-svc` | LoadBalancer, port 80 → 8080 |

---

## Deployment Commands Reference

```bash
# Build for the correct platform
docker build --platform linux/amd64 -t IMAGE_URL .
docker push IMAGE_URL

# Get cluster credentials
gcloud container clusters get-credentials flask-cluster --region us-central1

# Deploy / update
kubectl apply -f k8s/
kubectl rollout restart deployment/flask-app
kubectl rollout status deployment/flask-app

# Debug
kubectl get pods
kubectl get svc
kubectl describe pod POD_NAME
kubectl logs POD_NAME
kubectl get events --sort-by=.lastTimestamp
```

---

## Next Step: CI/CD Pipeline

The above commands will be automated via GitHub Actions so every push to `main`:
1. Builds the image (on `amd64` by default — no platform flag needed)
2. Pushes to Artifact Registry
3. Rolls out the new image to GKE with zero downtime
