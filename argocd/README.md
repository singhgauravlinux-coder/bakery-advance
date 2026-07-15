# ArgoCD — GitOps CD for the bakery platform

One `ApplicationSet` (`applicationset.yaml`) generates four Argo CD
`Application`s from `helm/bakery/` — one per stage, each pointed at its own
`values-<env>.yaml`:

| Application     | Namespace     | Sync policy                          |
|------------------|---------------|---------------------------------------|
| `bakery-dev`     | `bakery-dev`  | automated (prune + selfHeal)          |
| `bakery-uat`     | `bakery-uat`  | automated (prune + selfHeal)          |
| `bakery-cug`     | `bakery-cug`  | **manual** — canary is human-gated    |
| `bakery-prod`    | `bakery-prod` | **manual** — canary is human-gated    |

`dev`/`uat` are true GitOps: CI (`.github/workflows/build-images.yml`) bumps
`helm/bakery/values-dev.yaml`'s image tag on every push to `main`, and
ArgoCD picks it up automatically. `cug`/`prod` intentionally do NOT
auto-sync — `scripts/canary-promote.sh` drives those via direct
`helm upgrade` during a rollout (weight-shifting is ephemeral, not something
you want a Git commit per step for), and writes the *final* promoted image
tag back to `values-<env>.yaml` on `promote`, so Git and the live cluster
agree again and a later `argocd app sync` doesn't undo the release.

## One-time setup

```bash
# 1. Point the project + apps at your fork
grep -rl 'YOUR_GITHUB_USERNAME' argocd/ | xargs sed -i \
  "s#YOUR_GITHUB_USERNAME/bakery-3d-fullstack#<you>/<your-repo>#g"

# 2. Install ArgoCD itself, if you haven't already
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Register the project and the ApplicationSet
kubectl apply -f argocd/project.yaml
kubectl apply -f argocd/applicationset.yaml
```

## Per-environment secrets (NOT managed by ArgoCD)

Two things live outside Git on purpose and must exist in each `bakery-<env>`
namespace **before** that Application's first sync, or the pods that need
them will sit in `ContainerCreating`/`CrashLoopBackOff` forever:

```bash
# app-passwords — mounted as a volume by auth-service
NAMESPACE=bakery-<env> ./scripts/generate-app-secrets.sh --apply

# bakery-db-secret / razorpay-credentials ARE templated by the chart
# (helm/bakery/templates/secrets.yaml) from dbSecret.*/razorpay.* values —
# but cug/prod refuse to render with the dev placeholder passwords. Set
# real ones directly on the Argo CD Application (keeps them out of Git):
argocd app set bakery-cug  --helm-set-string dbSecret.POSTGRES_PASSWORD=<real> --helm-set-string dbSecret.AUTH_TOKEN_SECRET=<real>
argocd app set bakery-prod --helm-set-string dbSecret.POSTGRES_PASSWORD=<real> --helm-set-string dbSecret.AUTH_TOKEN_SECRET=<real>
```

(`dev`/`uat` are fine with the chart's defaults — that's local/QA data.)

Alternatively, replace `templates/secrets.yaml` with External Secrets
Operator or Sealed Secrets once you have a real secrets backend; the rest
of the chart doesn't care how `bakery-db-secret` gets created, only that it
exists.

## Day to day

```bash
argocd app list
argocd app get bakery-prod
argocd app sync bakery-uat        # dev/uat also auto-sync on their own
argocd app sync bakery-prod       # required for cug/prod — nothing happens automatically

# canary rollout on cug/prod (unchanged from before, still your entry point):
scripts/canary-promote.sh prod deploy ghcr.io/<you>/bakery-microservices/api-gateway:sha-abc123
scripts/canary-promote.sh prod shift 10
scripts/canary-promote.sh prod shift 50
scripts/canary-promote.sh prod promote   # also commits+pushes the new image tag to values-prod.yaml
```
