.PHONY: up down logs ps smoke k8s-deploy k8s-deploy-fast k8s-delete k8s-status

## ---------- docker compose (local / client demo) ----------
up:            ## Build and start the whole stack
	docker compose up --build -d
	@echo "Frontend  → http://localhost:8080"
	@echo "API       → http://localhost:3000/api/products"
	@echo "Adminer   → http://localhost:8081  (postgres / bakery / bakery)"

down:          ## Stop everything (add -v manually to wipe data)
	docker compose down

logs:          ## Tail JSON logs from every service
	docker compose logs -f --tail=50

ps:
	docker compose ps

smoke:         ## Quick end-to-end check against the local stack
	./scripts/smoke-test.sh

## ---------- kubernetes ----------
k8s-deploy:    ## Sequential rollout: each service must be healthy before the next
	./scripts/deploy.sh

k8s-deploy-fast: ## Old behaviour: apply everything at once (no per-service checks)
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f k8s/data/
	kubectl apply -f k8s/services/
	kubectl apply -f k8s/policies.yaml
	kubectl apply -f k8s/ingress.yaml

k8s-delete:
	kubectl delete namespace bakery

k8s-status:
	kubectl -n bakery get pods,svc,ingress,hpa
