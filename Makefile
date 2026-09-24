# Shortcuts for the CacheClosedException repro. Run `make` to list targets.

KUBECTL := kubectl --context k3d-geode-repro

.DEFAULT_GOAL := help
# Scenarios share one cluster and one load pod, so never run them in parallel.
.NOTPARALLEL:
.PHONY: help up down rebuild status stop-load clean-logs results all broken fixed \
        broken-delete broken-liveness fixed-delete fixed-liveness broken-close-cache

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*## "} {printf "  %-20s %s\n", $$1, $$2}'

## ---- Setup
up: ## Create the k3d cluster, build + import images, start the Geode server
	./scripts/cluster-up.sh

rebuild: ## Rebuild the client jar + image and import it (after changing app/)
	cd app && mvn -q -DskipTests package
	docker build -q -t repro-client:dev app
	k3d image import -c geode-repro repro-client:dev

down: ## Delete the k3d cluster
	./scripts/cluster-down.sh

## ---- Scenarios
broken-delete: ## Current config: pod deleted under load (rollout / scale-down)
	./scripts/run.sh broken delete

broken-liveness: ## Current config: liveness probe fails, kubelet restarts the container
	./scripts/run.sh broken liveness

fixed-delete: ## Fixed config: pod deleted under load
	./scripts/run.sh fixed delete

fixed-liveness: ## Fixed config: liveness probe fails, kubelet restarts the container
	./scripts/run.sh fixed liveness

broken-close-cache: ## App code calls cache.close() while the pod keeps running
	./scripts/run.sh broken close-cache

broken: broken-delete broken-liveness ## Both broken scenarios
fixed: fixed-delete fixed-liveness ## Both fixed scenarios

all: broken-delete broken-liveness fixed-delete fixed-liveness broken-close-cache ## All five scenarios, then the results table
	@echo
	@./scripts/results.sh

## ---- Inspect
results: ## One-line result for the latest run of each scenario
	@./scripts/results.sh

status: ## Pods in the repro cluster
	$(KUBECTL) get pods -o wide

stop-load: ## Stop the load generator pod
	$(KUBECTL) delete pod load --ignore-not-found

clean-logs: ## Delete saved run evidence under logs/
	rm -rf logs
