#!/usr/bin/env bash
# =============================================================================
# canary-promote.sh — canary lifecycle for api-gateway + frontend (cug/prod)
# =============================================================================
# Canary only exists in cug and prod (see helm/bakery/values-{cug,prod}.yaml).
# Traefik's IngressRoute splits traffic between the "-stable" and "-canary"
# Service/Deployment pair for each edge service, weighted by canary.weight.
#
# Usage:
#   scripts/canary-promote.sh <env> deploy <image-tag>   # roll out a candidate at 0% traffic
#   scripts/canary-promote.sh <env> shift <0-100>         # move N% of traffic to the canary
#   scripts/canary-promote.sh <env> promote               # canary becomes the new stable
#   scripts/canary-promote.sh <env> rollback               # send traffic back to stable, scale canary to 0
#   scripts/canary-promote.sh <env> status                 # print current weight + rollout health
#
# Example — a full release to prod:
#   scripts/canary-promote.sh prod deploy ghcr.io/.../api-gateway:sha-abc123
#   scripts/canary-promote.sh prod shift 10   # watch metrics/logs for a while
#   scripts/canary-promote.sh prod shift 50
#   scripts/canary-promote.sh prod promote
set -euo pipefail

ENV="${1:-}"; ACTION="${2:-}"; ARG="${3:-}"
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helm/bakery"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
EDGE_SERVICES=(api-gateway frontend)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mxx  %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$ENV" == "cug" || "$ENV" == "prod" ]] || fail "canary only applies to cug or prod (got: '${ENV}'). dev/uat deploy without it."
[[ -n "$ACTION" ]] || fail "usage: $0 <cug|prod> <deploy|shift|promote|rollback|status> [arg]"

RELEASE="bakery-${ENV}"
NAMESPACE="bakery-${ENV}"
VALUES_FILE="${CHART_DIR}/values-${ENV}.yaml"

helm_set() {
  # $1: extra --set args (space-separated key=value already quoted by caller)
  # shellcheck disable=SC2086
  helm upgrade "$RELEASE" "$CHART_DIR" -f "$VALUES_FILE" -n "$NAMESPACE" --reuse-values $1
}

wait_for_canary() {
  for svc in "${EDGE_SERVICES[@]}"; do
    log "Waiting for ${svc}-canary rollout"
    if ! kubectl -n "$NAMESPACE" rollout status "deployment/${svc}-canary" --timeout="$ROLLOUT_TIMEOUT"; then
      fail "${svc}-canary failed to become ready — traffic was NOT shifted. Inspect: kubectl -n ${NAMESPACE} describe pods -l app=${svc},track=canary"
    fi
  done
}

case "$ACTION" in
  deploy)
    [[ -n "$ARG" ]] || fail "usage: $0 <env> deploy <image-tag>"
    log "Deploying candidate '${ARG}' to ${svc:-canary track} at 0% traffic (${RELEASE})"
    helm_set "--set canary.enabled=true --set canary.imageTag=${ARG} --set canary.weight=0"
    wait_for_canary
    log "Candidate is live at 0% traffic. Next: $0 ${ENV} shift 10"
    ;;

  shift)
    [[ "$ARG" =~ ^[0-9]+$ ]] && [[ "$ARG" -ge 0 && "$ARG" -le 100 ]] || fail "usage: $0 <env> shift <0-100>"
    log "Confirming canary pods are healthy before shifting traffic to ${ARG}%"
    wait_for_canary
    log "Shifting ${ARG}% of ${RELEASE} ingress traffic to canary"
    helm_set "--set canary.weight=${ARG}"
    log "Now at ${ARG}% canary / $((100 - ARG))% stable"
    ;;

  promote)
    CANARY_TAG=$(helm get values "$RELEASE" -n "$NAMESPACE" -a -o json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("canary",{}).get("imageTag",""))')
    [[ -n "$CANARY_TAG" ]] || fail "no canary.imageTag on release '${RELEASE}' — nothing to promote. Run 'deploy' first."
    log "Promoting canary image '${CANARY_TAG}' to stable, then scaling canary back to 0%"
    helm_set "--set global.imageTag=${CANARY_TAG} --set canary.weight=0 --set canary.imageTag="
    log "Waiting for the new stable rollout"
    for svc in "${EDGE_SERVICES[@]}"; do
      kubectl -n "$NAMESPACE" rollout status "deployment/${svc}-stable" --timeout="$ROLLOUT_TIMEOUT" \
        || fail "${svc}-stable failed to roll out the promoted image — investigate before retrying"
    done
    log "Promoted. 100% of traffic is now on the new stable; canary track is idle at 0%."

    # --- Keep git (ArgoCD's source of truth) in sync with what we just did.
    # Without this, values-${ENV}.yaml would still say the OLD image tag, and
    # the next `argocd app sync` (manual or triggered by someone else) would
    # revert this promotion straight back to it.
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      log "Recording the promoted image tag in ${VALUES_FILE}"
      # Scoped replace: only the imageTag under the top-level `global:` block,
      # so this can't accidentally touch canary.imageTag too.
      python3 - "$VALUES_FILE" "$CANARY_TAG" <<'PY'
import sys, re
path, tag = sys.argv[1], sys.argv[2]
text = open(path).read()
text2, n = re.subn(r'(^global:\n(?:.*\n)*?\s*imageTag:\s*).*$', r'\1' + tag, text, count=1, flags=re.MULTILINE)
if n:
    open(path, 'w').write(text2)
PY
      if ! git -C "$REPO_ROOT" diff --quiet -- "$VALUES_FILE"; then
        git -C "$REPO_ROOT" -c user.name="canary-promote.sh" -c user.email="canary-bot@local" \
          add "$VALUES_FILE"
        git -C "$REPO_ROOT" -c user.name="canary-promote.sh" -c user.email="canary-bot@local" \
          commit -m "ci: promote ${ENV} to ${CANARY_TAG} [skip ci]" -q
        if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
          git -C "$REPO_ROOT" push origin HEAD:main \
            && log "Pushed promotion commit — git now matches the live cluster." \
            || log "Committed locally but push failed — push manually so ArgoCD doesn't see this as drift."
        fi
      fi
    else
      log "Not a git checkout — remember to bump global.imageTag to '${CANARY_TAG}' in ${VALUES_FILE} by hand so ArgoCD stays in sync."
    fi

    if command -v argocd >/dev/null 2>&1 && argocd account get-user-info >/dev/null 2>&1; then
      log "Triggering argocd app sync bakery-${ENV}"
      argocd app sync "bakery-${ENV}" || log "argocd sync failed/skipped — sync manually: argocd app sync bakery-${ENV}"
    else
      log "argocd CLI not available/authenticated — if this env is ArgoCD-managed, run: argocd app sync bakery-${ENV}"
    fi
    ;;

  rollback)
    log "Rolling back: sending 100% of traffic to stable, disabling canary"
    helm_set "--set canary.weight=0"
    log "Traffic restored to stable. Canary pods are still running — delete them with:"
    echo "  kubectl -n ${NAMESPACE} delete deployment api-gateway-canary frontend-canary"
    ;;

  status)
    echo "Release:   ${RELEASE}"
    echo "Namespace: ${NAMESPACE}"
    helm get values "$RELEASE" -n "$NAMESPACE" 2>/dev/null | grep -A3 '^canary:' || echo "(no canary values found)"
    kubectl -n "$NAMESPACE" get deploy -l 'track in (stable,canary)' -o custom-columns='NAME:.metadata.name,TRACK:.metadata.labels.track,READY:.status.readyReplicas,DESIRED:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image'
    ;;

  *)
    fail "unknown action '${ACTION}'. Use deploy|shift|promote|rollback|status."
    ;;
esac
