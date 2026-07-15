#!/usr/bin/env bash
# Sequential Kubernetes deployment for the bakery stack.
#
# Deploys the data layer first, then every microservice ONE AT A TIME in
# dependency order. Each service must pass its readiness probes
# (kubectl rollout status) before the next one is applied. If any rollout
# fails, the script stops, prints diagnostics, and exits non-zero — nothing
# after the broken service gets touched.
#
# Usage:
#   ./scripts/deploy.sh                 # deploy everything
#   ROLLOUT_TIMEOUT=300s ./scripts/deploy.sh
set -euo pipefail

NAMESPACE="bakery"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
K8S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/k8s"

# Dependency-ordered service list: platform services first, then domain
# services, the gateway second-to-last, and the frontend last.
SERVICES=(
  auth-service
  user-service
  product-catalog-service
  inventory-service
  pricing-service
  cart-service
  order-service
  payment-service
  delivery-service
  notification-service
  review-service
  search-service
  recommendation-service
  promotion-service
  loyalty-service
  recipe-service
  baking-schedule-service
  supplier-service
  analytics-service
  media-service
  invoice-service
  currency-service
  language-service
  api-gateway
  frontend
)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mxx  %s\033[0m\n' "$*" >&2; exit 1; }

diagnose() {
  local app="$1"
  echo "---- diagnostics for ${app} ----"
  kubectl -n "$NAMESPACE" get pods -l "app=${app}" -o wide || true
  kubectl -n "$NAMESPACE" describe pods -l "app=${app}" | tail -n 25 || true
  kubectl -n "$NAMESPACE" logs -l "app=${app}" --tail=30 --all-containers || true
}

wait_for_rollout() {
  local kind="$1" name="$2"
  if ! kubectl -n "$NAMESPACE" rollout status "${kind}/${name}" --timeout="$ROLLOUT_TIMEOUT"; then
    diagnose "$name"
    fail "${name} failed to become ready within ${ROLLOUT_TIMEOUT} — aborting (remaining services NOT deployed)"
  fi
}

# ---------------------------------------------------------------- namespace
log "Applying namespace"
kubectl apply -f "${K8S_DIR}/namespace.yaml"

# ------------------------------------------------------------------ secrets
if [[ -f "${K8S_DIR}/secrets.yaml" ]]; then
  log "Applying secrets (k8s/secrets.yaml)"
  kubectl apply -f "${K8S_DIR}/secrets.yaml"
else
  log "No k8s/secrets.yaml found — payment-service will run in mock mode (see k8s/secrets.example.yaml)"
fi

# Apply application secrets (app-passwords, etc.) if they exist
if [[ -d "${K8S_DIR}/secrets" ]]; then
  log "Applying application secrets (k8s/secrets/)"
  kubectl apply -f "${K8S_DIR}/secrets/"
fi

# --------------------------------------------------------------- data layer
log "Deploying data layer (postgres, redis, adminer)"
kubectl apply -f "${K8S_DIR}/data/"
wait_for_rollout statefulset postgres
wait_for_rollout deployment redis
wait_for_rollout deployment adminer

# ------------------------------------------------- services, one at a time
for svc in "${SERVICES[@]}"; do
  manifest="${K8S_DIR}/services/${svc}.yaml"
  [[ -f "$manifest" ]] || fail "Manifest not found: ${manifest}"
  log "Deploying ${svc}"
  kubectl apply -f "$manifest"
  wait_for_rollout deployment "$svc"
  echo "    ${svc} is ready ✔"
done

# ------------------------------------------------------- policies + ingress
log "Applying network policies"
kubectl apply -f "${K8S_DIR}/policies.yaml"

log "Applying Traefik ingress"
kubectl apply -f "${K8S_DIR}/ingress.yaml"

log "All ${#SERVICES[@]} services deployed and healthy"
kubectl -n "$NAMESPACE" get pods
