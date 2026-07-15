#!/usr/bin/env bash
# =============================================================================
# generate-app-secrets.sh — SHA-hashed application passwords for auth-service
# =============================================================================
# Application passwords (user accounts) are stored as SHA-256 hashes in a
# Kubernetes Secret so auth-service can verify login attempts without storing
# plaintext. Every password is taken from a GitHub Actions secret, hashed once,
# and stored in the Secret — it never needs rotation and does not change with
# every CD run (unlike generate-secrets.sh which rotates infrastructure creds).
#
# Passwords come from GitHub Actions secrets named:
#   APP_PASSWORD_<USERNAME>   e.g., APP_PASSWORD_AMELIE, APP_PASSWORD_TOMAS
#
# Usage:
#   ./scripts/generate-app-secrets.sh                    # print manifest
#   ./scripts/generate-app-secrets.sh --apply            # apply to cluster
#   ./scripts/generate-app-secrets.sh --apply --watch    # apply and watch secret updates
#
# The Secret is visible with:
#   kubectl -n bakery get secrets app-passwords
#   kubectl -n bakery get secret app-passwords -o yaml    # shows base64-encoded hashes
#
# To add/change a password:
#   1. Add or update the GitHub secret: Settings → Secrets and variables → Actions
#      Name it APP_PASSWORD_<USERNAME> (uppercase username)
#   2. The next CD run will regenerate the Secret with the new hash
#
# Password format stored in Secret:
#   username:sha256_hash
# =============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-bakery}"
SECRET_NAME="${SECRET_NAME:-app-passwords}"
APPLY=false
WATCH=false

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --watch) WATCH=true ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

sha256() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

# Collect all APP_PASSWORD_* env vars and build the secret data
# Each entry is: USERNAME:SHA256_HASH_OF_PASSWORD (lowercase username)
SECRET_DATA=""
FOUND_ANY=false

# Demo accounts (provided as env vars in the loop)
for var in $(compgen -e | grep '^APP_PASSWORD_'); do
  FOUND_ANY=true
  USERNAME=$(echo "$var" | sed 's/^APP_PASSWORD_//' | tr '[:upper:]' '[:lower:]')
  PASSWORD="${!var}"
  PASSWORD_HASH=$(sha256 "$PASSWORD")
  SECRET_DATA+="    ${USERNAME}:${PASSWORD_HASH}
"
done

# Provide defaults if no GitHub Secrets are configured (dev/local testing)
if [ "$FOUND_ANY" = false ]; then
  echo "::info::No APP_PASSWORD_* GitHub secrets found; using demo defaults." >&2
  # Demo users seeded in db/init.sql, must match auth-service fallback
  SECRET_DATA=$(cat <<'EOF'
    amelie: $(printf 'baguette' | sha256sum | awk '{print $1}')
    tomas: $(printf 'croissant' | sha256sum | awk '{print $1}')
EOF
  )
  # Evaluate the $() subshells
  AMELIE_HASH=$(sha256 "baguette")
  TOMAS_HASH=$(sha256 "croissant")
  SECRET_DATA="    amelie:${AMELIE_HASH}
    tomas:${TOMAS_HASH}"
fi

MANIFEST=$(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: crumb-and-ember
    bakery.dev/managed-by: generate-app-secrets
  annotations:
    bakery.dev/updated-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    bakery.dev/algorithm: "sha256(password)"
    bakery.dev/format: "username:sha256_hash"
type: Opaque
stringData:
  passwords.txt: |
${SECRET_DATA}
EOF
)

if [ "$APPLY" = false ]; then
  echo "$MANIFEST"
  exit 0
fi

echo "Applying ${SECRET_NAME} to namespace ${NAMESPACE}..."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
echo "$MANIFEST" | kubectl apply -f -
echo "Done. Inspect with: kubectl -n ${NAMESPACE} get secret ${SECRET_NAME} -o yaml"

if [ "$WATCH" = true ]; then
  echo "Watching for secret updates..."
  kubectl -n "$NAMESPACE" get secret "${SECRET_NAME}" -w
fi
