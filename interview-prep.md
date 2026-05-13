# Gumloop Senior Infrastructure Engineer Interview Prep

## Interview Format

- 1 hour, screen share
- Given a GitHub repo with a simple Flask app
- Tasks: Dockerize → Deploy on GKE → CI/CD pipeline
- Allowed: web search, AI tools, any IDE
- Recommended cloud: GCP

---

## Time Budget

| Phase | Task | Time |
|---|---|---|
| 1 | Dockerize the Flask app | ~10 min |
| 2 | Deploy to K8s on GCP | ~25 min |
| 3 | CI/CD pipeline | ~20 min |
| — | Buffer for issues | ~5 min |

---

## Tools to Install & Verify

```bash
python --version
docker --version
git --version
gcloud --version
kubectl version --client
```

### gcloud Setup

```bash
# Install
brew install --cask google-cloud-sdk

# Auth
gcloud auth login
gcloud auth application-default login
gcloud config set project PROJECT_ID

# Install kubectl and GKE auth plugin via gcloud
gcloud components install kubectl
gcloud components install gke-gcloud-auth-plugin
```

> `gke-gcloud-auth-plugin` is easy to forget — missing it will break `kubectl` on GKE.

---

## Phase 1: Dockerize (10 min)

### Dockerfile

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["python", "-m", "gunicorn", "--bind", "0.0.0.0:8080", "app:app"]
```

### .dockerignore

```
__pycache__
*.pyc
*.pyo
.git
.env
*.md
```

### Test locally

```bash
docker build -t flask-app .
docker run -p 8080:8080 flask-app
```

Key points:
- Use `slim` base image — smaller and faster
- Use `gunicorn`, not the Flask dev server
- Always test the image locally before pushing

---

## Phase 2: GCP + K8s Deployment (25 min)

### 1. Create GKE Cluster

```bash
# Autopilot is faster to provision than standard
gcloud container clusters create-auto flask-cluster \
  --region us-central1 \
  --project PROJECT_ID
```

### 2. Get kubectl Credentials

```bash
gcloud container clusters get-credentials flask-cluster \
  --region us-central1
```

### 3. Push Image to GCR

```bash
gcloud auth configure-docker
docker tag flask-app gcr.io/PROJECT_ID/flask-app:latest
docker push gcr.io/PROJECT_ID/flask-app:latest
```

### 4. K8s Manifests

`k8s/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: flask-app
  template:
    metadata:
      labels:
        app: flask-app
    spec:
      containers:
      - name: flask-app
        image: gcr.io/PROJECT_ID/flask-app:latest
        ports:
        - containerPort: 8080
```

`k8s/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: flask-app-svc
spec:
  type: LoadBalancer
  selector:
    app: flask-app
  ports:
  - port: 80
    targetPort: 8080
```

### 5. Deploy

```bash
kubectl apply -f k8s/
kubectl get pods
kubectl get svc   # wait for EXTERNAL-IP
```

### Debugging Commands

```bash
kubectl logs <pod-name>
kubectl describe pod <pod-name>
kubectl get events --sort-by=.lastTimestamp
```

---

## Phase 3: CI/CD Pipeline (20 min)

### GCP Service Account Setup

```bash
# Create service account
gcloud iam service-accounts create github-actions

# Grant required permissions
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:github-actions@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/container.developer"

gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:github-actions@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.admin"

# Download key
gcloud iam service-accounts keys create key.json \
  --iam-account=github-actions@PROJECT_ID.iam.gserviceaccount.com
```

Add contents of `key.json` as `GCP_SA_KEY` secret in GitHub. Also add `GCP_PROJECT_ID`.

### GitHub Actions Workflow

`.github/workflows/deploy.yml`:
```yaml
name: Build and Deploy

on:
  push:
    branches: [main]

env:
  PROJECT_ID: ${{ secrets.GCP_PROJECT_ID }}
  IMAGE: gcr.io/${{ secrets.GCP_PROJECT_ID }}/flask-app

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - uses: google-github-actions/auth@v2
      with:
        credentials_json: ${{ secrets.GCP_SA_KEY }}

    - uses: google-github-actions/setup-gcloud@v2

    - run: gcloud auth configure-docker

    - name: Build and Push
      run: |
        docker build -t $IMAGE:$GITHUB_SHA .
        docker push $IMAGE:$GITHUB_SHA

    - uses: google-github-actions/get-gke-credentials@v2
      with:
        cluster_name: flask-cluster
        location: us-central1

    - name: Deploy
      run: |
        kubectl set image deployment/flask-app \
          flask-app=$IMAGE:$GITHUB_SHA
        kubectl rollout status deployment/flask-app
```

---

## Pre-Interview Checklist

- [ ] Docker Desktop is running
- [ ] `gcloud` authenticated and `gke-gcloud-auth-plugin` installed
- [ ] Done a full end-to-end dry run on a throwaway GCP project
- [ ] Boilerplate YAML/Dockerfile/workflow in a personal repo ready to copy
- [ ] Know your `kubectl` debugging commands
- [ ] GCP billing enabled on the project you'll use

---

## Time Management Tips

- Don't over-engineer — 2 replicas, LoadBalancer service, and a basic workflow is enough to pass
- GKE Autopilot provisioning takes 5-7 min — talk through what you're doing while waiting
- Use `kubectl rollout status` to show you understand deployment health
- If stuck, say what you'd do next rather than going silent

## Things to Mention (Shows Senior Thinking)

Given more time, you would add:
- Liveness/readiness probes
- Resource requests and limits
- Kubernetes Secrets for env vars (not plaintext in manifests)
- Separate staging and production environments
- Image vulnerability scanning in CI
- Horizontal Pod Autoscaler (HPA)
