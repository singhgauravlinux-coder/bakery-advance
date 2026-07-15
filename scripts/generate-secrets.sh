#!/usr/bin/env bash
# =============================================================================
# generate-secrets.sh — SHA-256-derived platform credentials for Kubernetes
# =============================================================================
# Every credential is deterministically derived with SHA-256 from:
#
#     sha256( MASTER_SEED : <component> : <rotation-id> )
#
# so the same (seed, commit) pair always produces the same passwords, and a
# new commit deployed by CD produces NEW passwords — i.e. credentials rotate
# automatically with every CD run. GitHub Actions calls this script with
# ROTATION_ID=$GITHUB_SHA (see .github/workflows/rotate-secrets.yml).
#
# The result is applied as a normal Kubernetes Secret, so it is visible with:
#
#     kubectl -n bakery get secrets
#     kubectl -n bakery describe secret bakery-db-secret     # shows SHA fingerprints
#     kubectl -n bakery get secret bakery-db-secret -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
#
# Each secret is annotated with the git SHA it was rotated for and a SHA-256
# fingerprint of every credential, so you can audit *which* value is live
# without decoding it.
#
# Usage:
#   MASTER_SEED=<long-random-string> ./scripts/generate-secrets.sh            # print manifest
#   MASTER_SEED=... ROTATION_ID=$(git rev-parse HEAD) ./scripts/generate-secrets.sh --apply
#   MASTER_SEED=... ./scripts/generate-secrets.sh --apply --sync-db          # also ALTER the live pg password + restart consumers
#
# MASTER_SEED must be stored as a GitHub Actions secret (SECRET_MASTER_SEED);
# it never appears in manifests, logs, or the repo.
# =============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-bakery}"
SECRET_NAME="${SECRET_NAME:-bakery-db-secret}"
ROTATION_ID="${ROTATION_ID:-static}"        # CI passes the commit SHA here
APPLY=false
SYNC_DB=false
for arg in "$@"; do
  case "$arg" in
    --apply)   APPLY=true ;;
    --sync-db) SYNC_DB=true ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

if [ -z "${MASTER_SEED:-}" ]; then
  echo "ERROR: MASTER_SEED is required (export it or set the SECRET_MASTER_SEED GitHub secret)." >&2
  exit 1
fi

sha() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

# SHA-256-derived credential: hex digest of seed:component:rotation-id.
# 64 hex chars = 256 bits of derived material; we keep 40 chars (160 bits),
# far beyond brute-force reach and safe in connection strings.
derive() { sha "${MASTER_SEED}:${1}:${ROTATION_ID}" | cut -c1-40; }

PG_USER="bakery"
PG_DB="bakery"
PG_PASSWORD="$(derive postgres-password)"
AUTH_TOKEN_SECRET="$(derive auth-token-secret)"
REDIS_PASSWORD="$(derive redis-password)"
ADMIN_API_KEY="$(derive admin-api-key)"
DATABASE_URL="postgresql://${PG_USER}:${PG_PASSWORD}@postgres:5432/${PG_DB}"

# Public fingerprints (sha256 of each secret value) — safe to expose in
# annotations; lets anyone verify which credential generation is live.
FP_PG="$(sha "$PG_PASSWORD" | cut -c1-16)"
FP_AUTH="$(sha "$AUTH_TOKEN_SECRET" | cut -c1-16)"
FP_REDIS="$(sha "$REDIS_PASSWORD" | cut -c1-16)"
FP_ADMIN="$(sha "$ADMIN_API_KEY" | cut -c1-16)"

MANIFEST=$(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: crumb-and-ember
    bakery.dev/managed-by: generate-secrets
  annotations:
    bakery.dev/rotation-id: "${ROTATION_ID}"
    bakery.dev/rotated-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    bakery.dev/algorithm: "sha256(seed:component:rotation-id)"
    bakery.dev/fingerprint.postgres-password: "${FP_PG}"
    bakery.dev/fingerprint.auth-token-secret: "${FP_AUTH}"
    bakery.dev/fingerprint.redis-password: "${FP_REDIS}"
    bakery.dev/fingerprint.admin-api-key: "${FP_ADMIN}"
type: Opaque
stringData:
  POSTGRES_USER: ${PG_USER}
  POSTGRES_PASSWORD: ${PG_PASSWORD}
  POSTGRES_DB: ${PG_DB}
  DATABASE_URL: ${DATABASE_URL}
  AUTH_TOKEN_SECRET: ${AUTH_TOKEN_SECRET}
  REDIS_PASSWORD: ${REDIS_PASSWORD}
  ADMIN_API_KEY: ${ADMIN_API_KEY}
EOF
)

if [ "$APPLY" = false ]; then
  echo "$MANIFEST"
  exit 0
fi

echo "Applying ${SECRET_NAME} (rotation-id: ${ROTATION_ID}) to namespace ${NAMESPACE}..."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
echo "$MANIFEST" | kubectl apply -f -
echo "Done. Inspect with: kubectl -n ${NAMESPACE} get secrets"

if [ "$SYNC_DB" = true ]; then
  # Rotating the Secret does not change a *running* Postgres user's password
  # (the container env only applies on first init), so sync it live, then
  # restart every deployment that consumes the secret to pick up new values.
  if kubectl -n "$NAMESPACE" get statefulset/postgres deploy/postgres >/dev/null 2>&1 || \
     kubectl -n "$NAMESPACE" get deploy postgres >/dev/null 2>&1; then
    echo "Syncing live Postgres password..."
    kubectl -n "$NAMESPACE" exec deploy/postgres -- \
      psql -U "$PG_USER" -d "$PG_DB" -c "ALTER USER ${PG_USER} WITH PASSWORD '${PG_PASSWORD}';" || \
      echo "WARN: could not ALTER USER (is postgres up yet?). New pods will still get the new secret."
  fi
  echo "Restarting consumers of ${SECRET_NAME}..."
  for d in $(kubectl -n "$NAMESPACE" get deploy -o name); do
    if kubectl -n "$NAMESPACE" get "$d" -o yaml | grep -q "$SECRET_NAME"; then
      kubectl -n "$NAMESPACE" rollout restart "$d"
    fi
  done
  echo "Rotation complete."
fi
