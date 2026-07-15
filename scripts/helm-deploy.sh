#!/usr/bin/env bash
# =============================================================================
# helm-deploy.sh — deploy one bakery environment with Helm
# =============================================================================
# Usage:
#   ./scripts/helm-deploy.sh dev
#   ./scripts/helm-deploy.sh uat
#   ./scripts/helm-deploy.sh cug  --set global.imageTag=sha-abc123
#   IMAGE_TAG=sha-abc123 ./scripts/helm-deploy.sh prod
#
# dev/uat: plain rollout, no canary (values-{dev,uat}.yaml keep canary.enabled=false).
# cug/prod: this installs/updates *stable* only; use scripts/canary-promote.sh
#           to roll out and shift traffic to a new candidate afterwards.
set -euo pipefail

ENV="${1:-}"; shift || true
[[ "$ENV" =~ ^(dev|uat|cug|prod)$ ]] || { echo "usage: $0 <dev|uat|cug|prod> [extra --set args]" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="${ROOT_DIR}/helm/bakery"
RELEASE="bakery-${ENV}"
NAMESPACE="bakery-${ENV}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

EXTRA_SET=()
[[ -n "${IMAGE_TAG:-}" ]] && EXTRA_SET+=(--set "global.imageTag=${IMAGE_TAG}")

# auth-service mounts the app-passwords Secret as a volume; it must exist
# BEFORE `helm upgrade --wait` starts waiting on auth-service's rollout, or
# a first-ever deploy to a fresh namespace deadlocks (pod stuck
# ContainerCreating, --wait times out). Create the namespace and apply the
# secret first, then let Helm own everything else.
log "Ensuring namespace ${NAMESPACE} exists"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

log "Applying app-passwords secret (auth-service) before rollout"
NAMESPACE="$NAMESPACE" "${ROOT_DIR}/scripts/generate-app-secrets.sh" --apply

log "helm upgrade --install ${RELEASE} -n ${NAMESPACE} (${ENV})"
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  -f "${CHART_DIR}/values-${ENV}.yaml" \
  -n "$NAMESPACE" --create-namespace \
  --wait --timeout "$ROLLOUT_TIMEOUT" \
  "${EXTRA_SET[@]}" "$@"

log "Deployed. Pods in ${NAMESPACE}:"
kubectl -n "$NAMESPACE" get pods
