# DevSecOps & SRE Assessment: memory-leak microservice

Secure CI/CD → GitOps (ArgoCD) → observability + alerting, all running locally (Minikube + Calico), no cloud accounts.

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
| `scripts/protect-main.sh` | Creates the branch ruleset (PR required, `PR Gate` required) |
| `k8s/base/` | Kustomize: namespace, quota, RBAC, config, NetworkPolicies, 3 Deployments, Service, PDB |
| `argocd/application.yaml` | ArgoCD Application |
| `monitoring/` | Helm values, Grafana dashboard JSON, Grafana alert provisioning |
| `scripts/0*.sh` | Cluster / ArgoCD / monitoring install |

## Reproduce

Prereqs: docker, minikube, kubectl, helm, gh (GitHub CLI), a GitHub repo.

1. **Push this repo to GitHub.** Replace `YOUR_GH_USER` in `k8s/base/kustomization.yaml` (lowercase username) and `YOUR_REPO` / `YOUR_GH_USER` in `argocd/application.yaml` (the install script patches the latter for you).
2. **Repo settings:** *Settings → Actions → General → Workflow permissions: Read and write*. Then protect `main`: `./scripts/protect-main.sh <user>/<repo>`.
3. **First image build:** push a branch, open a PR (PR pipeline runs), merge it. The release pipeline pushes the images to GHCR and commits the real tags. Make the GHCR package **public** (Profile → Packages → memleak-app → Package settings) so the cluster can pull without credentials.
4. **Cluster:** `./scripts/01-create-cluster.sh`
5. **ArgoCD:** `./scripts/02-install-argocd.sh <user> <repo>` (prints admin password).
6. **Monitoring:** `export SLACK_WEBHOOK_URL=...` (optional) then `./scripts/03-install-monitoring.sh`.
7. Grafana: `kubectl -n monitoring port-forward svc/kps-grafana 3000:80` → http://localhost:3000, admin / `admin-change-me` (change it in the values file).

## Task 1: design choices

- **Dockerfile:** `python:X-alpine` (≈50 MB), no build tooling because the app is stdlib-only, `apk upgrade` for patched OS packages, fixed non-root UID, only `app.py` copied, `.dockerignore`, container `HEALTHCHECK` using Python (no curl in image).
- **PR pipeline gates** (all aggregated into one required check, `PR Gate`): flake8; Bandit SAST with `B104` (0.0.0.0) skipped; gitleaks; pytest on 3.11/3.12/3.13; image build + smoke test (healthcheck and non-root UID assertion) + Trivy (fails on HIGH/CRITICAL with fixes available).
- **Release pipeline:** triggers on push to main (= PR merge). Builds three images `ghcr.io/<user>/memleak-app:py3.X-<sha>` with provenance + SBOM, updates `k8s/base/kustomization.yaml` with `yq`, commits `[skip ci]`. `paths-ignore: k8s/**` prevents loops. The ruleset lets the GitHub Actions app bypass the PR requirement for that one bot commit.

## Task 2: Kubernetes footprint

- **Namespace** `memleak` with Pod Security Admission `restricted` enforced.
- **Three Deployments** (one per Python version) + **one Service** selecting `app=memleak-app`, so kube-proxy spreads traffic across all three.
- **Memory:** request 128Mi, **limit 400Mi** (the app climbs ~3.3 MB/s from 100MB, so it is OOMKilled at roughly 90–100s, before the 500MB target). CPU 50m/200m.
- **ConfigMap + Secret** via `envFrom` (the Secret is a dummy; use Sealed Secrets/ESO/SOPS for real ones), **initContainer** preflight check, **RBAC** (dedicated ServiceAccount, token not auto-mounted, Role limited to `get` on its own ConfigMap), **NetworkPolicies** (default deny; ingress 8080 only from the namespace and `monitoring`; egress DNS only), **ResourceQuota + LimitRange**, **PodDisruptionBudget**, hardened `securityContext` (non-root, read-only rootfs, drop ALL caps, seccomp RuntimeDefault), liveness + readiness probes on `/healthcheck`.
- **ArgoCD:** `automated` sync with `prune` and `selfHeal`.
- NetworkPolicies need a CNI that enforces them, hence `--cni calico` in the cluster script.

## Task 3: Observability

- **Metrics:** kube-prometheus-stack (Prometheus, Grafana, node-exporter, kube-state-metrics, cAdvisor). Alertmanager is disabled; Grafana does the alerting.
- **Logs:** Loki (single binary) + Grafana Alloy tailing pod logs; Loki is a provisioned Grafana datasource.
- **Dashboard "Memleak SRE Overview":** ready/unready pods, OOMKilled count, restarts; memory per pod against the 400Mi limit; CPU per pod; node CPU / memory / disk; CPU and memory by namespace; live application logs and log rate.
- **Alerts** (Grafana-managed, provisioned from `monitoring/alerting/`): `MemleakPodNotReady`, `MemleakDeploymentUnavailable` (health-check failures) and `MemleakOOMKilled` (restart in last 5 min with last termination reason `OOMKilled`). Contact point `slack-sre` reads `SLACK_WEBHOOK_URL` from the `grafana-slack` secret.

## Demo / verification

```bash
kubectl -n memleak get pods -w               # restarts climb every ~100s
kubectl -n memleak describe pod <pod> | grep -A3 "Last State"   # Reason: OOMKilled
./scripts/watch-oom.sh
# load-balancing across the 3 versions
kubectl -n memleak run curl --image=curlimages/curl --restart=Never --rm -it \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"curl","image":"curlimages/curl","command":["sh","-c","for i in $(seq 1 6); do curl -s memleak-app/healthcheck; echo; done"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
# GitOps: merge any PR touching app/ and watch ArgoCD roll the new tag
```

## Notes / caveats

- `app.py` is functionally unchanged; only trailing whitespace and PEP8 blank lines were fixed so flake8 passes.
- `test/test.py` is named `test.py`, so `pytest.ini` adds it to `python_files`.
- Secret scanning (gitleaks) is free for personal repos; organisation repos need a gitleaks licence key.

