#!/usr/bin/env bash
# Local cluster with Calico CNI (needed so NetworkPolicies are actually enforced).
set -euo pipefail
minikube start --profile memleak --cpus 4 --memory 6144 --cni calico --kubernetes-version stable
kubectl config use-context memleak
kubectl get nodes
