#!/usr/bin/env bash
# Installs Prometheus + Grafana (kube-prometheus-stack), Loki, Alloy, dashboard and alert rules.
# Optional: export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/... before running.
set -euo pipefail
cd "$(dirname "$0")/.."

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Slack webhook secret (falls back to a dummy URL so Grafana still starts)
kubectl -n monitoring create secret generic grafana-slack \
  --from-literal=SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-http://localhost/slack-webhook-not-configured}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Dashboard + alerting provisioning are picked up by the Grafana sidecars via labels
kubectl -n monitoring create configmap memleak-dashboard \
  --from-file=memleak-sre-dashboard.json=monitoring/dashboards/memleak-sre-dashboard.json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring label configmap memleak-dashboard grafana_dashboard=1 --overwrite

kubectl -n monitoring create configmap memleak-alerting \
  --from-file=monitoring/alerting/rules.yaml \
  --from-file=monitoring/alerting/contactpoints.yaml \
  --from-file=monitoring/alerting/policies.yaml \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring label configmap memleak-alerting grafana_alert=1 --overwrite

helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring \
  -f monitoring/kube-prometheus-stack-values.yaml --wait --timeout 10m
helm upgrade --install loki grafana/loki -n monitoring -f monitoring/loki-values.yaml --wait --timeout 10m
helm upgrade --install alloy grafana/alloy -n monitoring -f monitoring/alloy-values.yaml --wait --timeout 5m

echo "Grafana: kubectl -n monitoring port-forward svc/kps-grafana 3000:80  ->  http://localhost:3000 (admin / admin-change-me)"
