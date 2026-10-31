# DevSecOps & SRE Assessment: memory-leak microservice

Secure CI/CD → GitOps (ArgoCD) → observability + alerting, using only free/open-source tools that run locally (Minikube/kind + Calico). No cloud accounts are required; the only external services are GitHub (repo, Actions) and GHCR (image registry).

## Architecture

```
 PR ──► PR Pipeline ──────────────► merge to main ──► Release Pipeline
        flake8 · bandit · gitleaks            │        build 3 images (py3.11/3.12/3.13) → GHCR
        pytest (3 versions)                   │        yq: bump tags in k8s/base/kustomization.yaml
        docker build + smoke + Trivy          │        commit "[skip ci]" back to main
        └─ "PR Gate" = required check         ▼
                                      ArgoCD (automated, prune, selfHeal)
                                              │ watches k8s/base
                                              ▼
   namespace memleak:  3 Deployments (py311/py312/py313) ◄── 1 Service (selector app=memleak-app)
   limit 400Mi → OOMKilled in ~100s, restart, repeat
                                              │
   namespace monitoring: Prometheus + Grafana (kube-prometheus-stack) · Loki · Alloy (log shipper)
   Grafana: dashboard "Memleak SRE Overview" + alerts (pod unready, OOMKilled) → Slack
```

## Repository layout

| Path | Purpose |
|---|---|
| `app/app.py`, `test/test.py` | Application and pytest suite |
| `Dockerfile` | Alpine, non-root UID 10001, stdlib-only, `PYTHON_VERSION` build-arg, healthcheck |
| `.github/workflows/pr-pipeline.yml` | PR gate (only `pull_request` → `main`) |
| `.github/workflows/release-pipeline.yml` | Build/push images + GitOps tag bump (only `push` → `main`) |
| `.github/workflows/cluster-verify.yml` | Manual end-to-end cluster verification on a throwaway kind cluster |
| `scripts/protect-main.sh` | Creates the branch ruleset (PR required, `PR Gate` required) |
| `k8s/base/` | Kustomize: namespace, quota, RBAC, config, NetworkPolicies, 3 Deployments, Service, PDB |
| `argocd/application.yaml` | ArgoCD Application |
| `monitoring/` | Helm values, Grafana dashboard JSON, Grafana alert provisioning |
| `scripts/0*.sh` | Cluster / ArgoCD / monitoring install for a local cluster |

## Task 1: Docker image and secure CI/CD

- **Dockerfile:** `python:X-alpine`, no build tooling because the app is stdlib-only, `apk upgrade` for patched OS packages, fixed non-root UID (10001), only `app.py` copied, `.dockerignore`, and a container `HEALTHCHECK` that uses Python (no curl in the image). `pip`, `setuptools` and `wheel` are removed from the final image: the app never needs them, and Trivy flagged HIGH CVEs in the copies of `wheel` and `jaraco.context` that `setuptools` bundles in the Python 3.11 image.
- **Branch protection:** repository ruleset `protect-main` (created by `scripts/protect-main.sh`): changes only through a Pull Request, the `PR Gate` status check must pass, no force-push, no deletion.
- **PR pipeline** (runs only for pull requests into `main`). Every job feeds one required check, `PR Gate`:
  - flake8 (lint)
  - Bandit SAST, with `B104` (binding to 0.0.0.0) ignored as requested
  - gitleaks (secret scanning)
  - pytest on Python 3.11 / 3.12 / 3.13
  - image build for each Python version, a smoke test (`/healthcheck` returns healthy, container runs as non-root), then a Trivy scan that fails the build on fixable HIGH/CRITICAL vulnerabilities. Trivy runs from its official container image.
- **Release pipeline** (runs only when a PR is merged into `main`): builds three images `ghcr.io/<user>/memleak-app:py3.X-<sha>` with provenance and SBOM, rewrites the tags in `k8s/base/kustomization.yaml` with `yq`, and commits the change back with `[skip ci]`. `paths-ignore: k8s/**` prevents loops.
  - On a personal repository GitHub does not allow the Actions app on a ruleset bypass list. The ruleset therefore lets the repository admin bypass, and the tag-bump commit is pushed with a fine-grained personal access token stored as the repository secret `RELEASE_PAT` (Contents: read and write, this repository only). Everything else goes through pull requests.

## Task 2: Kubernetes footprint

- **Namespace** `memleak` with Pod Security Admission `restricted` enforced.
- **Three Deployments** (one per Python version) and **one Service** selecting `app=memleak-app`, so traffic is spread across all three.
- **Memory:** request 128Mi, **limit 400Mi**. The app climbs about 3.3 MB/s from 100 MB, so it is OOMKilled after roughly 90–100 seconds, restarts, and repeats. CPU 50m / 200m.
- **ConfigMap + Secret** via `envFrom` (the Secret holds a dummy value; use Sealed Secrets / External Secrets / SOPS for real ones), an **initContainer** preflight check, **RBAC** (dedicated ServiceAccount with no auto-mounted token, Role limited to `get` on its own ConfigMap), **NetworkPolicies** (default deny; ingress on 8080 only from the namespace and `monitoring`; egress DNS only), **ResourceQuota + LimitRange**, a **PodDisruptionBudget**, a hardened `securityContext` (non-root, read-only root filesystem, all capabilities dropped, seccomp RuntimeDefault), and liveness/readiness probes on `/healthcheck`.
- **ArgoCD:** `automated` sync with `prune` and `selfHeal`, tracking `k8s/base` on `main`.
- NetworkPolicies need a CNI that enforces them, so clusters are created with Calico.

## Task 3: Observability and alerting

- **Metrics:** kube-prometheus-stack (Prometheus, Grafana, node-exporter, kube-state-metrics, cAdvisor), installed with Helm. Alertmanager is disabled; Grafana does the alerting.
- **Logs:** Loki (single binary, small persistent volume) with Grafana Alloy tailing pod logs; Loki is a provisioned Grafana datasource.
- **Dashboard "Memleak SRE Overview":** ready/unready pods, OOMKilled count, container restarts; memory per pod against the 400Mi limit; CPU per pod; node CPU / memory / disk; CPU and memory by namespace; live application logs and log rate.
- **Alerts** (Grafana-managed, provisioned from `monitoring/alerting/`): `MemleakPodNotReady` and `MemleakDeploymentUnavailable` (health-check failures) and `MemleakOOMKilled` (a restart in the last 5 minutes with last termination reason `OOMKilled`). The contact point `slack-sre` reads `SLACK_WEBHOOK_URL` from the `grafana-slack` secret; set it before installing to receive the alerts in Slack.

## Verification

The `Cluster Verify (kind)` workflow (`.github/workflows/cluster-verify.yml`, run manually from the Actions tab) builds a throwaway kind cluster with Calico on a GitHub-hosted runner, installs ArgoCD and the monitoring stack exactly as the local scripts do, and checks:

| Check | What is verified |
|---|---|
| GitOps | ArgoCD syncs the app from this repo and all 3 pods become Ready |
| Service | one Service has 3 ready endpoints (one per Deployment) |
| NetworkPolicy | a pod in another namespace cannot reach the app |
| OOMKilled | every pod has a 400Mi memory limit and ends up with last state `OOMKilled` |
| Grafana | the dashboard, the Prometheus and Loki datasources, the three alert rules and the `slack-sre` contact point exist |
| Prometheus | sees the OOMKilled pods and their memory metrics |
| Loki | returns the application logs |
| Alerting | the `MemleakOOMKilled` alert is `firing` |

The results appear as a table on each run's summary page. The run also uploads a `cluster-evidence` artifact (dashboard and alert screenshots, pod state, Grafana/Prometheus/Loki API output). GitHub keeps artifacts for 90 days.

The cluster was verified on GitHub-hosted runners because the author's laptop has 8 GB of RAM, which is not enough to run the full stack locally. The local scripts below create the same environment on a machine with enough memory.

## Reproduce locally

Prerequisites: Docker, minikube, kubectl, Helm, GitHub CLI (`gh`), and a GitHub repository. The full stack needs about 4 CPUs and 6 GB of RAM for minikube (edit `scripts/01-create-cluster.sh` for a smaller machine).

1. **Push this repo to GitHub** as a public repo. Replace `YOUR_GH_USER` in `k8s/base/kustomization.yaml` with your lowercase username (the install script patches `argocd/application.yaml` for you).
2. **Repo settings:**
   - *Settings → Actions → General → Workflow permissions: Read and write*.
   - Create a fine-grained personal access token (this repository only, *Contents: Read and write*) and save it as the Actions secret `RELEASE_PAT`.
3. **First image build:** push to `main`. The release pipeline publishes the images to GHCR and commits the real tags (pull them with `git pull`). Packages inherit the repository visibility, so a public repo gives public images that the cluster can pull without credentials.
4. **Protect `main`:** `./scripts/protect-main.sh <user>/<repo>`. From then on, changes go through pull requests.
5. **Cluster:** `./scripts/01-create-cluster.sh`
6. **ArgoCD:** `./scripts/02-install-argocd.sh <user> <repo>` (prints the admin password).
7. **Monitoring:** optionally `export SLACK_WEBHOOK_URL=...`, then `./scripts/03-install-monitoring.sh`.
8. **Grafana:** `kubectl -n monitoring port-forward svc/kps-grafana 3000:80`, then open http://localhost:3000 (admin / `admin-change-me`; change it in the values file).

### Demo commands

```bash
kubectl -n memleak get pods -w                                  # restarts climb every ~100s
kubectl -n memleak describe pod <pod> | grep -A3 "Last State"   # Reason: OOMKilled
./scripts/watch-oom.sh
# GitOps: merge a PR touching app/ and watch ArgoCD roll out the new image tag
```

## Notes

- `app.py` is functionally unchanged; only trailing whitespace and PEP8 blank lines were fixed so flake8 passes.
- `test/test.py` is named `test.py`, so `pytest.ini` adds it to `python_files`.
- gitleaks is free for personal repositories; organisation repositories need a gitleaks licence key.
- The Kubernetes Secret is a placeholder. Real secrets should never be committed in plain text.
- The cluster-verify workflow pre-loads the ArgoCD Redis image into the kind node because `public.ecr.aws` rate-limits shared CI runner addresses (HTTP 429).
