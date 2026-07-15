<div align="center">

![Crumb & Ember — cloud-native bakery](docs/assets/ember/hero.svg)

</div>

> 🎬 **The diagrams are alive** — pure-CSS animations baked into the SVGs (floating cubes,
> flowing request arrows, pulsing status lines). GitHub renders them natively; they honor
> `prefers-reduced-motion`. No JS, no GIFs, no image hosting.

## 🎨 Pick your theme

Four full color themes ship in [`docs/assets/`](docs/assets/) — every diagram in every theme:

| | | |
|---|---|---|
| 🔥 **ember** *(default)* | <img src="docs/assets/ember/hero.svg" width="380"/> | butter & espresso |
| 🌌 **midnight** | <img src="docs/assets/midnight/hero.svg" width="380"/> | tokyo-night blues |
| 🍵 **matcha** | <img src="docs/assets/matcha/hero.svg" width="380"/> | green tea & cream |
| 🫐 **berry** | <img src="docs/assets/berry/hero.svg" width="380"/> | plum & rosé |

Switch the whole README in one command:

```bash
sed -i 's#docs/assets/[a-z]*/#docs/assets/midnight/#g' README.md   # or matcha / berry / ember
```

<div align="center">

![Node](https://img.shields.io/badge/Node.js-20_LTS-339933?logo=node.js&logoColor=white)
![Express](https://img.shields.io/badge/Express-4.x-000000?logo=express&logoColor=white)
![Swagger](https://img.shields.io/badge/Swagger_UI-/api/docs-85EA2D?logo=swagger&logoColor=black)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)
![Redis](https://img.shields.io/badge/Redis-7-DC382D?logo=redis&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose_v2-2496ED?logo=docker&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.29+_·_Traefik-326CE5?logo=kubernetes&logoColor=white)
![Logs](https://img.shields.io/badge/logs-100%25_structured_JSON-orange)

*A production-grade e-commerce platform for an artisan bakery — built the way real platforms are built.*

[⚡ Quick Start](#-quick-start-one-command) · [🏗 Architecture](#-architecture) · [📖 Swagger UI](#-api-docs--swagger-ui) · [🛒 Checkout Pipeline](#-the-checkout-pipeline) · [🔌 Port Map](#-one-service-one-port) · [☸️ Kubernetes](#️-deploying-to-kubernetes) · [🛠 Troubleshooting](#-troubleshooting)

</div>

---

## ⚡ Quick Start (one command)

> The entire platform — database, cache, gateway, 21 services, storefront — on any machine with Docker.

```bash
docker compose up --build -d        # or: make up
```

| What | Where | Credentials |
|---|---|---|
| 🥐 **Bakery storefront** | http://localhost:8080 | — |
| 📖 **Swagger UI** | http://localhost:3000/api/docs | — |
| 🚪 **API gateway** (route index) | http://localhost:3000/api | — |
| 🩺 **Platform health** | http://localhost:3000/api/status | — |
| 🗄 **Adminer (DB UI)** | http://localhost:8081 | server `postgres` · `bakery` / `bakery` |
| 🐘 **PostgreSQL** | localhost:5432 | `bakery` / `bakery` |
| 👤 **Demo login** | `amelie@crumbandember.dev` | `baguette` |
| 🎟 **Promo codes** | `CRUMB10` · `DAYOLD50` | −10% / −50% |

```bash
make smoke      # login → token verify → cart in Redis → order in Postgres ✅
make logs       # live JSON log firehose from all 26 containers
```

---

## 🏗 Architecture

![System architecture — isometric](docs/assets/ember/architecture.svg)

One entry point, two paths: Traefik sends `/` to the nginx storefront and `/api` to the
gateway, which stamps every request with an `x-request-id` and proxies to the owning
domain service on **its own port**. Carts live in Redis with a 7-day TTL; users,
products, orders, payments and invoices live in PostgreSQL.

---

## 📖 API Docs — Swagger UI

The gateway serves interactive documentation for all **47 endpoints across 21 services**,
with try-it-out enabled — no Postman required.

| Endpoint | Compose | Kubernetes |
|---|---|---|
| **Swagger UI** (interactive) | http://localhost:3000/api/docs | http://bakery.local/api/docs |
| **OpenAPI 3 spec** (Postman/Insomnia import) | http://localhost:3000/api/openapi.json | http://bakery.local/api/openapi.json |
| **Route index** | http://localhost:3000/api | http://bakery.local/api |
| **Live upstream health** (all services, one call) | http://localhost:3000/api/status | http://bakery.local/api/status |

---

## 🛒 The Checkout Pipeline

![Checkout pipeline — isometric](docs/assets/ember/checkout-flow.svg)

One click in the storefront drives seven services, and the UI narrates each hop live:
*"Order o_x91k2 received — taking payment… — scheduling delivery…"*. Every other service
is visible too:

| You see | Service behind it |
|---|---|
| 🧺 Basket icon + live badge, slide-out drawer | **cart-service** (Redis, 7-day TTL) |
| 👤 Sign in / Register modal, guest-basket merge on login | **auth-service** (scrypt + HMAC tokens) |
| `27 in stock` / `only 3 left` / `sold out` badges | **inventory-service** |
| Net / VAT / total in the basket | **pricing-service** `/quote` |
| Promo box — try `CRUMB10` or `DAYOLD50` | **promotion-service** |
| ★★★★★ reviews, read & post per product | **review-service** |
| Header search box | **search-service** |
| "Pairs well today: …" | **recommendation-service** |
| 🔴 Out-of-the-oven rail, past bakes struck through | **baking-schedule-service** |
| Footer health grid — one dot per service, 30 s refresh | gateway **`/api/status`** |
| Every click tracked | **analytics-service** |

---

## 🔌 One Service, One Port

Each service listens on its own port (`PORT` env → compose host port → k8s Service/containerPort):

| Port | Service | Port | Service |
|---|---|---|---|
| **3000** | api-gateway | 3011 | review-service |
| 3001 | auth-service | 3012 | search-service |
| 3002 | user-service | 3013 | recommendation-service |
| 3003 | product-catalog-service | 3014 | promotion-service |
| 3004 | inventory-service | 3015 | loyalty-service |
| 3005 | pricing-service | 3016 | recipe-service |
| 3006 | cart-service | 3017 | baking-schedule-service |
| 3007 | order-service | 3018 | supplier-service |
| 3008 | payment-service | 3019 | analytics-service |
| 3009 | delivery-service | 3020 | media-service |
| 3010 | notification-service | 3021 | invoice-service |

*(Frontend 8080 · Adminer 8081 · Postgres 5432 · Redis internal.)* In compose you can
bypass the gateway and hit any service directly:

```bash
curl http://localhost:3006/carts/guest          # cart-service, straight to Redis
curl http://localhost:3003/products             # product-catalog, straight to Postgres
curl http://localhost:3017/schedule/today       # what's in the oven right now
```

---

## 📜 JSON Logging

Every container — Node services *and* nginx — emits one-line structured JSON on stdout,
ready for Fluent Bit / Loki / ELK, joined end-to-end by `x-request-id`:

```json
{"level":"info","time":"2026-07-10T15:04:05.123Z","service":"api-gateway","event":"proxy_request",
 "upstream":"http://order-service:3007","path":"/orders","status":201,"durationMs":14,"requestId":"req_k3x9d2ab"}
```

```bash
docker compose logs -f | grep req_k3x9d2ab     # follow one request across every hop
```

---

## ☸️ Deploying to Kubernetes

21 Deployments with readiness/liveness probes, non-root + read-only rootfs + dropped
capabilities, HPA (2–6) on the gateway, PodDisruptionBudgets on the edge, Traefik Ingress.

```bash
# 1. Build & push (replace with YOUR registry — this is the #1 gotcha)
export REG=ghcr.io/<you>/bakery-microservices
for d in services/*/; do s=$(basename $d); docker build -t $REG/$s:latest $d && docker push $REG/$s:latest; done

# 2. Point manifests at your registry
grep -rl 'YOUR_GITHUB_USERNAME' k8s/ | xargs sed -i "s#ghcr.io/YOUR_GITHUB_USERNAME/bakery-microservices#$REG#g"

# 3. Ship it
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/data/ -f k8s/services/ -f k8s/ingress.yaml -f k8s/policies.yaml
echo "<ingress-ip>  bakery.local db.bakery.local" | sudo tee -a /etc/hosts

# 4. Watch it come up
kubectl -n bakery get pods -w
curl http://bakery.local/api/status | jq
```

This raw-manifest path is a quick way to try the whole stack in one throwaway
namespace. For real dev → uat → cug → prod promotion, use the Helm chart below.

---

## 🚦 Multi-stage deploys with canary (Helm)

`helm/bakery/` is one chart, deployed once per stage into its own namespace,
with a `values-<env>.yaml` per stage:

| Stage | Namespace | Purpose | Canary |
|---|---|---|---|
| `dev` | `bakery-dev` | fast iteration, 1 replica everywhere | off |
| `uat` | `bakery-uat` | QA/stakeholder sign-off, one build at a time | off |
| `cug` | `bakery-cug` | Closed User Group — limited real users on prod-like infra | **on** (starts at 0%) |
| `prod` | `bakery-prod` | full traffic | **on** (starts at 0%) |

Canary only applies to `api-gateway` and `frontend` — the two services
actually reachable from outside the cluster. Traefik's `IngressRoute`
natively splits traffic by weight between a `-stable` and `-canary`
Deployment/Service pair for each, so no extra controller (Flagger, Argo
Rollouts) is needed.

```bash
# Deploy/update a stage
./scripts/helm-deploy.sh dev
./scripts/helm-deploy.sh uat
./scripts/helm-deploy.sh cug
IMAGE_TAG=$(git rev-parse HEAD) ./scripts/helm-deploy.sh prod

# Roll out a candidate build to cug or prod behind canary
./scripts/canary-promote.sh prod deploy ghcr.io/<you>/bakery-microservices/api-gateway:sha-abc123
./scripts/canary-promote.sh prod shift 10      # watch metrics/logs
./scripts/canary-promote.sh prod shift 50
./scripts/canary-promote.sh prod status
./scripts/canary-promote.sh prod promote       # canary becomes the new stable
./scripts/canary-promote.sh prod rollback      # or: send traffic back to stable instantly
```

Before a stage is usable, apply its secrets (each namespace gets its own):

```bash
NAMESPACE=bakery-prod MASTER_SEED=$(openssl rand -hex 32) ./scripts/generate-secrets.sh --apply
NAMESPACE=bakery-prod ./scripts/generate-app-secrets.sh --apply
```

`cug`/`prod` refuse to render if `dbSecret.POSTGRES_PASSWORD` /
`AUTH_TOKEN_SECRET` are still the dev placeholders — pass real values with
`--set-string` or a gitignored values file. Note: `helm/bakery/templates/secrets.yaml`
and `scripts/generate-secrets.sh` can both manage `bakery-db-secret` — pick
one owner per environment so a later `helm upgrade` doesn't stomp a rotated
credential (or vice versa).

**CI/CD:** `.github/workflows/build-images.yml` builds+pushes every image on
push to `main` and bumps `dev`'s image tag in Git. `argocd/` has an
ApplicationSet that turns this into full GitOps — dev/uat auto-sync from
Git, cug/prod stay manual (canary promotion is a deliberate action, not an
auto-sync). See **[`argocd/README.md`](argocd/README.md)** for setup.

---

## 🛠 Troubleshooting

| Symptom | Meaning | Fix |
|---|---|---|
| Storefront shows static data, footer says `degraded` | Gateway is up, some upstreams aren't | `curl /api/status` — it names the down services |
| Pods in `ImagePullBackOff` | Placeholder registry never replaced | Step 2 above; rebuild **all** images after the port change |
| `/api/xyz` → `No upstream for that path` | Prefix not in the route table | `GET /api` lists every valid prefix |
| Checkout stops at "taking payment…" | payment-service down or missing secrets | `kubectl -n bakery logs deploy/payment-service` |
| `bakery.local` unreachable | hosts entry / ingress IP | `kubectl -n traefik get svc` → add to `/etc/hosts` |

---

<div align="center">

**Baked with 21 services, zero magic, and a healthy respect for structured logging.** 🥖

*Diagrams are hand-built, CSS-animated isometric SVGs in [`docs/assets/`](docs/assets/) — four themes, zero image hosting, rendered natively by GitHub.*

</div>


## ✨ New: 3D colourful frontend

The frontend (`services/frontend/index.html`) is now a candy-bright, 3D-themed single-page app:

- **Three.js hero** — floating 3D donuts (with sprinkles), cupcake, macarons and croissants with mouse-parallax camera
- **Dimensional UI** — chunky offset shadows, 3D tilt-on-hover product cards, candy palette (strawberry / butter / pistachio / blueberry)
- **Full API integration** — products, baking schedule, reviews, cart, promos (`CRUMB10`), auth, checkout chain (order → payment → delivery → invoice → loyalty → notification), live platform status in the footer
- **Offline preview mode** — if the gateway is unreachable it falls back to the seeded menu and a local basket, so the page works standalone too
- The previous minimal frontend is kept at `services/frontend/index.legacy.html`
- **No platform internals are exposed to shoppers**: the customer frontend has no API-doc links, no service-status widget, and no error copy that names services or infrastructure. Operators still have everything at `/api/docs`, `/api/status` and `/api` on the gateway (port 3000) — it's just not linked from the storefront.

### 💱 New: currency-service (port 3022)

A dedicated currency-conversion microservice at `/api/currency` with **47 currencies** — INR ₹, AED د.إ (UAE Dirham), CNY ¥ (Chinese Yuan), GBP £, JPY ¥, USD $, KRW, SAR, BRL, ZAR and many more:

- `GET /api/currency` — all currencies with names, symbols, decimals and EUR rates
- `GET /api/currency/rates?base=INR` — full rate table rebased onto any currency
- `GET|POST /api/currency/convert?amount=8.5&from=EUR&to=INR` — convert with formatted output

The frontend has a currency picker in the header: every price, cart line and total converts live, JPY/KRW-style zero-decimal currencies format correctly, the choice persists across visits, and checkout charges the payment-service in the selected currency. Rates are demo reference rates — swap the table in `services/currency-service/server.js` for a live FX feed in production.

### 🔐 Password Management (SHA-256 + GitHub Secrets)

All application passwords are **SHA-256 hashed** and managed via GitHub Actions Secrets:
- Store plaintext passwords as **GitHub Secrets** named `APP_PASSWORD_<USERNAME>`
- A CD workflow (`rotate-secrets.yml`) hashes them and updates a Kubernetes Secret
- Auth-service reads the Secret and verifies logins with SHA-256 comparison
- Passwords are visible via `kubectl get secret app-passwords -o yaml` (hashes only, no plaintext)
- Full docs: see `PASSWORDS.md`

**Demo users** come with the platform (change anytime via GitHub Secrets):
- Email: `amelie@crumbandember.dev` / Password: `baguette` (update GitHub Secret `APP_PASSWORD_AMELIE` to change)
- Email: `tomas@example.com` / Password: `croissant` (update GitHub Secret `APP_PASSWORD_TOMAS` to change)

To add a new user password: create a GitHub secret, and the next CD run updates the Kubernetes Secret automatically.

Run everything with `make up`, then open http://localhost:8080 (demo login: `amelie@crumbandember.dev` / `baguette`).
