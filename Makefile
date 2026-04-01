# ==============================================================================
# Copyright (c) 2026 Jeffrey Jonathan Jennings
#
# @author Jeffrey Jonathan Jennings (J3)
#
# Confluent Platform + Apache Flink on Minikube — End-to-End Makefile
#
# Orchestrates the full lifecycle of a local Confluent Platform environment
# running on Minikube, from prerequisite installation through Flink job
# deployment.  Phases include:
#   1. Prerequisite tooling (Docker, kubectl, Minikube, Helm, Gradle)
#   2. Minikube cluster management (start, stop, delete)
#   3. Confluent for Kubernetes (CFK) operator
#   4. Confluent Platform components in KRaft mode (Kafka, Schema Registry,
#      Connect, ksqlDB, REST Proxy, Control Center)
#   5. Control Center browser access via port-forwarding
#   6. Apache Flink 2.1.1 (cert-manager, Confluent Flink Kubernetes Operator
#      1.130, session cluster deployment, Flink UI)
#   7. Confluent Manager for Apache Flink (CMF) 2.1
#   8. Kafka UI (Provectus Helm chart)
#   9. Flink JAR build (Gradle shadow JAR) and REST API job submission
# ==============================================================================

# To setup from scratch on a new Vultr VM, run the following commands in order:
# make install-prereqs   # installs docker, kubectl, minikube, helm
# make cp-up             # Minikube → CFK operator → CP → Kafka UI
# make flink-up          # cert-manager → Flink operator → CMF → session cluster

# Once everything is up, you can access the UIs:
# http://localhost:8080	Kafka UI
# http://localhost:9021	Control Center
# http://localhost:8081	Flink UI

CONFLUENT_MANIFEST  ?= k8s/base/confluent-platform-c3++.yaml
NAMESPACE           ?= confluent
MINIKUBE_CPUS       ?= 6
MINIKUBE_MEM        ?= 20480
MINIKUBE_DISK       ?= 50g

# Detect the Minikube node architecture (fallback to host architecture if kubectl is unavailable).
MINIKUBE_NODE_ARCH  := $(shell kubectl get node -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || uname -m)
ifeq ($(MINIKUBE_NODE_ARCH),x86_64)
MINIKUBE_NODE_ARCH := amd64
endif
ifeq ($(MINIKUBE_NODE_ARCH),aarch64)
MINIKUBE_NODE_ARCH := arm64
endif

# CMF manages Flink via confluentinc/cp-flink images — not the open-source flink image
FLINK_IMAGE         ?= confluentinc/cp-flink:2.1.1-cp1-java21$(if $(filter arm64,$(MINIKUBE_NODE_ARCH)),-arm64,)
FLINK_OPERATOR_VER  ?= 1.130.0
FLINK_VERSION       ?= v2_1
FLINK_CLUSTER_NAME  ?= flink-basic
FLINK_MANIFEST      ?= k8s/base/flink-basic-deployment.yaml
FLINK_RBAC_MANIFEST ?= k8s/base/flink-rbac.yaml
CERT_MANAGER_VER    ?= v1.18.2
CMF_VER             ?= 2.1.0
CMF_ENV_NAME        ?= dev-local

# Ports for port-forwarding to local machine (Control Center, CMF, Flink UI, Kafka UI)
KAFKA_UI_PORT       ?= 8080
C3_PORT             ?= 9021
FLINK_UI_PORT       ?= 8081
CMF_PORT            ?= 8080

SHELL               := /bin/bash
.SHELLFLAGS         := -eu -o pipefail -c

.DEFAULT_GOAL       := help

# Detect the running platform for package manager selection
UNAME_S            := $(shell uname -s)
IS_DARWIN          := $(filter Darwin,$(UNAME_S))
IS_LINUX           := $(filter Linux,$(UNAME_S))

# Directory of the current Makefile
mkfile_dir         := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------
.PHONY: help
help: ## Show this help message
	@echo ""
	@echo "  Confluent Platform + Apache Flink on Minikube — Quickstart"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ------------------------------------------------------------------------------
# Phase 1: Prerequisites (macOS or Linux)
# ------------------------------------------------------------------------------
.PHONY: install-prereqs
install-prereqs: ## Install docker, kubectl, minikube, helm, and gradle via Homebrew (macOS) or apt-get (Linux)
	@echo "→ Installing prerequisites..."
	@if [ "$(IS_DARWIN)" = "Darwin" ]; then \
		(test -d /Applications/Docker.app || test -f /usr/local/bin/kubectl.docker) || brew install --cask docker; \
		brew install kubernetes-cli minikube helm gettext gradle; \
		echo "✔ Prerequisites installed. Launch Docker Desktop before running 'make minikube-start'."; \
	elif [ "$(IS_LINUX)" = "Linux" ]; then \
		command -v apt-get >/dev/null 2>&1 || { echo "✘ apt-get not found. Install prerequisites manually for your Linux distribution."; exit 1; }; \
		apt-get update; \
		apt-get install -y ca-certificates curl gnupg lsb-release docker.io gettext gradle openjdk-21-jdk; \
		JDK_RELEASE=/usr/lib/jvm/java-21-openjdk-$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')/release; \
		if [ -f "$$JDK_RELEASE" ] && ! grep -q IMAGE_TYPE "$$JDK_RELEASE"; then \
			echo 'IMAGE_TYPE="JDK"' >> "$$JDK_RELEASE"; \
		fi; \
		HOST_ARCH=$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'); \
		KUBECTL_VERSION=$$(curl -L -s https://dl.k8s.io/release/stable.txt); \
		curl -LO "https://dl.k8s.io/release/$$KUBECTL_VERSION/bin/linux/$$HOST_ARCH/kubectl"; \
		install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl; \
		curl -Lo /tmp/minikube "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-$$HOST_ARCH"; \
		install -o root -g root -m 0755 /tmp/minikube /usr/local/bin/minikube; \
		curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; \
		echo "✔ Prerequisites installed. Ensure Docker is running before running 'make minikube-start'."; \
	else \
		echo "✘ Unsupported OS: $(UNAME_S). Install prerequisites manually."; exit 1; \
	fi
	
.PHONY: check-prereqs
check-prereqs: ## Verify required tools are available
	@echo "→ Checking prerequisites..."
	@command -v docker    >/dev/null 2>&1 || (echo "✘ docker not found"    && exit 1)
	@command -v kubectl   >/dev/null 2>&1 || (echo "✘ kubectl not found"   && exit 1)
	@command -v minikube  >/dev/null 2>&1 || (echo "✘ minikube not found"  && exit 1)
	@command -v helm      >/dev/null 2>&1 || (echo "✘ helm not found"      && exit 1)
	@echo "✔ All prerequisites found."

# ------------------------------------------------------------------------------
# Phase 2: Minikube cluster
# ------------------------------------------------------------------------------
.PHONY: minikube-start
minikube-start: ## Start Minikube with resources required for Confluent Platform + Flink
	@echo "→ Starting Minikube (cpus=$(MINIKUBE_CPUS), memory=$(MINIKUBE_MEM), disk=$(MINIKUBE_DISK))..."
	@MINIKUBE_FORCE=""
	@if [ "$$EUID" = "0" ]; then \
		echo "⚠ Minikube Docker driver should not be used as root."; \
		if [ -t 1 ]; then \
			read -p "Continue with --force anyway? [y/N]: " answer; \
			case "$$answer" in \
				y|Y|yes|YES|Yes) MINIKUBE_FORCE="--force" ;; \
			*) echo "Aborting. Run as a non-root user or use 'minikube start --driver=none' instead."; exit 1 ;; \
			esac; \
		else \
			echo "Non-interactive shell detected; cannot prompt. Run as a non-root user or use 'minikube start --driver=none' instead."; exit 1; \
		fi; \
	fi; \
	minikube start \
		--driver=docker \
		$$MINIKUBE_FORCE \
		--cpus=$(MINIKUBE_CPUS) \
		--memory=$(MINIKUBE_MEM) \
		--disk-size=$(MINIKUBE_DISK)

.PHONY: minikube-status
minikube-status: ## Check Minikube and cluster node status
	minikube status
	kubectl get nodes

.PHONY: minikube-stop
minikube-stop: ## Stop the Minikube cluster
	minikube stop

.PHONY: minikube-delete
minikube-delete: ## Completely delete the Minikube cluster
	minikube delete

# ------------------------------------------------------------------------------
# Phase 3: Confluent Operator (CFK)
# ------------------------------------------------------------------------------
.PHONY: namespace
namespace: ## Create the 'confluent' namespace and set it as the default context
	@echo "→ Creating namespace '$(NAMESPACE)'..."
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl config set-context --current --namespace=$(NAMESPACE)
	@echo "✔ Namespace '$(NAMESPACE)' is active."

.PHONY: operator-install
operator-install: namespace ## Add the Confluent Helm repo and install the CFK Operator
	@echo "→ Adding Confluent Helm repo..."
	helm repo add confluentinc https://packages.confluent.io/helm
	helm repo update
	@echo "→ Installing Confluent Operator..."
	helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
		--namespace $(NAMESPACE)
	@echo "✔ Confluent Operator installed."

.PHONY: operator-status
operator-status: ## Verify the Confluent Operator pod is running
	kubectl get pods -n $(NAMESPACE)

.PHONY: operator-uninstall
operator-uninstall: ## Uninstall the Confluent Operator Helm release and wait for pod termination
	@helm uninstall confluent-operator -n $(NAMESPACE) --wait 2>/dev/null || echo "→ confluent-operator not installed, skipping."
	@echo "✔ Confluent Operator removed."

# ------------------------------------------------------------------------------
# Phase 4: Deploy Confluent Platform (KRaft mode)
# ------------------------------------------------------------------------------
.PHONY: cp-deploy
cp-deploy: ## Deploy all CP components: Kafka KRaft, Schema Registry, Connect, ksqlDB, REST Proxy, C3
	@test -f $(CONFLUENT_MANIFEST) \
		|| (echo "✘ Manifest not found at $(CONFLUENT_MANIFEST)" && exit 1)
	@echo "→ Applying Confluent Platform manifest from $(CONFLUENT_MANIFEST)"
	kubectl apply -f $(CONFLUENT_MANIFEST)
	@echo "✔ Manifest applied. Run 'make cp-watch' to follow pod startup."

.PHONY: cp-watch
cp-watch: ## Watch pods come up in the confluent namespace (Ctrl+C to exit)
	@if ! minikube status --format='{{.Host}}' 2>/dev/null | grep -q "Running"; then \
		echo "✘ Minikube is not running — nothing to watch. Run 'make minikube-start' first."; \
	elif ! kubectl get pods -n $(NAMESPACE) 2>/dev/null | grep -q .; then \
		echo "✘ No pods found in namespace '$(NAMESPACE)' — nothing to watch. Run 'make cp-core-up' first."; \
	else \
		kubectl get pods -n $(NAMESPACE) -w; \
	fi

.PHONY: cp-status
cp-status: ## Show current pod status for all CP components
	@if ! minikube status --format='{{.Host}}' 2>/dev/null | grep -q "Running"; then \
		echo "✘ Minikube is not running — nothing to get status on. Run 'make minikube-start' first."; \
	elif ! kubectl get pods -n $(NAMESPACE) 2>/dev/null | grep -q .; then \
		echo "✘ No pods found in namespace '$(NAMESPACE)' — nothing to get status on. Run 'make cp-core-up' first."; \
	else \
		kubectl get pods -n $(NAMESPACE); \
	fi

.PHONY: cp-delete
cp-delete: ## Remove all CP components, wait for termination, and clean up PVCs
	@echo "→ Deleting CP components from $(CONFLUENT_MANIFEST)..."
	@kubectl delete -f $(CONFLUENT_MANIFEST) --ignore-not-found=true 2>/dev/null || echo "→ CP components not found, skipping."
	@echo "→ Waiting for all CP pods to terminate (timeout 3m)..."
	@kubectl wait --for=delete pod \
		-l 'app in (kafka,kraftcontroller,connect,schemaregistry,ksqldb,kafkarestproxy,controlcenter)' \
		-n $(NAMESPACE) --timeout=180s 2>/dev/null || echo "→ Pods already gone or timeout reached."
	@echo "→ Deleting leftover PVCs in namespace '$(NAMESPACE)'..."
	@kubectl delete pvc --all -n $(NAMESPACE) --ignore-not-found=true 2>/dev/null || echo "→ No PVCs to clean up."
	@echo "✔ CP components and PVCs removed."

# ------------------------------------------------------------------------------
# Phase 5: Control Center access
# ------------------------------------------------------------------------------
.PHONY: c3-open
c3-open: ## Port-forward Control Center in the background and open it in your browser ('make c3-stop' to kill)
	@if lsof -iTCP:$(C3_PORT) -sTCP:LISTEN -t >/dev/null 2>&1; then \
		echo "→ Port $(C3_PORT) is already in use."; \
		echo "  Opening http://localhost:$(C3_PORT) in your browser."; \
		open http://localhost:$(C3_PORT); \
		exit 0; \
	fi
	@echo "→ Forwarding Control Center to http://localhost:$(C3_PORT) (background)"
	@kubectl port-forward -n $(NAMESPACE) controlcenter-0 $(C3_PORT):$(C3_PORT) >/dev/null 2>&1 & \
	echo $$! > /tmp/c3-pf.pid; \
	sleep 1; \
	if kill -0 $$(cat /tmp/c3-pf.pid) 2>/dev/null; then \
		echo "✔ Port-forward running (PID $$(cat /tmp/c3-pf.pid)). Stop with 'make c3-stop'."; \
		open http://localhost:$(C3_PORT); \
	else \
		echo "✘ Port-forward failed to start."; exit 1; \
	fi

.PHONY: c3-stop
c3-stop: ## Stop the background Control Center port-forward
	@if [ -f /tmp/c3-pf.pid ] && kill -0 $$(cat /tmp/c3-pf.pid) 2>/dev/null; then \
		kill $$(cat /tmp/c3-pf.pid); \
		rm -f /tmp/c3-pf.pid; \
		echo "✔ Control Center port-forward stopped."; \
	else \
		echo "→ No active Control Center port-forward found."; \
		rm -f /tmp/c3-pf.pid; \
	fi

# ------------------------------------------------------------------------------
# Phase 6: Apache Flink
# ------------------------------------------------------------------------------
.PHONY: flink-cert-manager
flink-cert-manager: ## Install cert-manager (required by Flink Kubernetes Operator)
	@echo "→ Installing cert-manager $(CERT_MANAGER_VER)..."
	kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/$(CERT_MANAGER_VER)/cert-manager.yaml
	@echo "→ Waiting for cert-manager pods to be ready (this takes ~60s)..."
	kubectl wait --for=condition=ready pod -l app=cert-manager -n cert-manager --timeout=180s
	kubectl wait --for=condition=ready pod -l app=cainjector -n cert-manager --timeout=180s
	kubectl wait --for=condition=ready pod -l app=webhook -n cert-manager --timeout=180s
	@echo "✔ cert-manager is ready."

.PHONY: flink-operator-install
flink-operator-install: namespace ## Install the Confluent Flink Kubernetes Operator $(FLINK_OPERATOR_VER) (required by CMF)
	@echo "→ Installing Confluent Flink Kubernetes Operator v$(FLINK_OPERATOR_VER)..."
	@helm repo add confluentinc https://packages.confluent.io/helm 2>/dev/null || true
	helm repo update
	# CMF requires the Confluent-packaged operator (confluentinc/flink-kubernetes-operator),
	# NOT the Apache OSS operator. watchNamespaces scopes it to the confluent namespace.
	helm upgrade --install cp-flink-kubernetes-operator confluentinc/flink-kubernetes-operator \
		--version "~$(FLINK_OPERATOR_VER)" \
		--namespace $(NAMESPACE) \
		--set watchNamespaces="{$(NAMESPACE)}" \
		--set webhook.create=false
	@echo "✔ Confluent Flink Kubernetes Operator $(FLINK_OPERATOR_VER) installed."

.PHONY: flink-operator-status
flink-operator-status: ## Check Flink operator pod status
	kubectl get pods -n $(NAMESPACE) | grep -E "flink|confluent-manager"

.PHONY: flink-operator-uninstall
flink-operator-uninstall: ## Uninstall the Confluent Flink Kubernetes Operator (safe to run even if not installed)
	@helm uninstall cp-flink-kubernetes-operator -n $(NAMESPACE) --wait 2>/dev/null || echo "→ cp-flink-kubernetes-operator not installed, skipping."

.PHONY: flink-rbac
flink-rbac: ## Apply supplemental RBAC so the flink SA can read services (needed for job submission)
	@echo "→ Applying Flink supplemental RBAC from $(FLINK_RBAC_MANIFEST)..."
	@test -f $(FLINK_RBAC_MANIFEST) || (echo "✘ $(FLINK_RBAC_MANIFEST) not found." && exit 1)
	kubectl apply -f $(FLINK_RBAC_MANIFEST)
	@echo "✔ Flink supplemental RBAC applied."

.PHONY: flink-deploy
flink-deploy: flink-rbac ## Deploy a Flink session cluster using $(FLINK_MANIFEST) (image=$(FLINK_IMAGE), version=$(FLINK_VERSION))
	@echo "→ Deploying Flink session cluster from $(FLINK_MANIFEST) (image=$(FLINK_IMAGE), flinkVersion=$(FLINK_VERSION))..."
	@test -f $(FLINK_MANIFEST) || (echo "✘ $(FLINK_MANIFEST) not found. Is it alongside the Makefile?" && exit 1)
	@command -v envsubst >/dev/null 2>&1 || (echo "✘ envsubst not found. Install gettext: brew install gettext" && exit 1)
	FLINK_IMAGE=$(FLINK_IMAGE) FLINK_VERSION=$(FLINK_VERSION) \
		envsubst '$$FLINK_IMAGE $$FLINK_VERSION' < $(FLINK_MANIFEST) | kubectl apply -f -
	@echo "✔ Flink cluster deployed (image=$(FLINK_IMAGE), flinkVersion=$(FLINK_VERSION))."

.PHONY: flink-status
flink-status: ## Show status of all Flink pods and FlinkDeployment CRs
	@echo "--- Pods ---"
	kubectl get pods -n $(NAMESPACE) | grep flink
	@echo ""
	@echo "--- FlinkDeployments ---"
	kubectl get flinkdeployment -n $(NAMESPACE)

.PHONY: flink-ui
flink-ui: ## Port-forward the Flink UI in the background and open it in your browser ('make flink-ui-stop' to kill)
	@if lsof -iTCP:$(FLINK_UI_PORT) -sTCP:LISTEN -t >/dev/null 2>&1; then \
		echo "→ Port $(FLINK_UI_PORT) is already in use."; \
		echo "  Opening http://localhost:$(FLINK_UI_PORT) in your browser."; \
		open http://localhost:$(FLINK_UI_PORT); \
		exit 0; \
	fi
	@FLINK_POD=$$(kubectl get pods -n $(NAMESPACE) -l component=jobmanager --no-headers -o custom-columns=":metadata.name" | head -1); \
	if [ -z "$$FLINK_POD" ]; then \
		echo "✘ No Flink JobManager pod found. Is the cluster deployed?"; exit 1; \
	fi; \
	echo "→ Forwarding Flink UI to http://localhost:$(FLINK_UI_PORT) (background)"; \
	echo "   Pod: $$FLINK_POD"; \
	kubectl port-forward -n $(NAMESPACE) $$FLINK_POD $(FLINK_UI_PORT):$(FLINK_UI_PORT) >/dev/null 2>&1 & \
	echo $$! > /tmp/flink-ui-pf.pid; \
	sleep 1; \
	if kill -0 $$(cat /tmp/flink-ui-pf.pid) 2>/dev/null; then \
		echo "✔ Port-forward running (PID $$(cat /tmp/flink-ui-pf.pid)). Stop with 'make flink-ui-stop'."; \
		open http://localhost:$(FLINK_UI_PORT); \
	else \
		echo "✘ Port-forward failed to start."; exit 1; \
	fi

.PHONY: flink-ui-stop
flink-ui-stop: ## Stop the background Flink UI port-forward
	@if [ -f /tmp/flink-ui-pf.pid ] && kill -0 $$(cat /tmp/flink-ui-pf.pid) 2>/dev/null; then \
		kill $$(cat /tmp/flink-ui-pf.pid); \
		rm -f /tmp/flink-ui-pf.pid; \
		echo "✔ Flink UI port-forward stopped."; \
	else \
		echo "→ No active Flink UI port-forward found."; \
		rm -f /tmp/flink-ui-pf.pid; \
	fi

.PHONY: flink-delete
flink-delete: ## Delete the Flink session cluster (safe to run even if cluster is down or not deployed)
	@# Also remove any stale plain Deployment left from a previous OSS Flink setup
	@kubectl delete deployment $(FLINK_CLUSTER_NAME) -n $(NAMESPACE) --ignore-not-found=true 2>/dev/null || true
	@kubectl delete flinkdeployment $(FLINK_CLUSTER_NAME) -n $(NAMESPACE) --ignore-not-found=true 2>/dev/null \
		&& echo "✔ Flink cluster '$(FLINK_CLUSTER_NAME)' deleted." \
		|| echo "→ Flink cluster not found or API server unreachable, skipping."

# ------------------------------------------------------------------------------
# Phase 7: Confluent Manager for Apache Flink (CMF)
# ------------------------------------------------------------------------------
.PHONY: cmf-install
cmf-install: ## Install CMF v$(CMF_VER) — requires Confluent Flink Operator to be running
	@echo "→ Installing Confluent Manager for Apache Flink (CMF) v$(CMF_VER)..."
	@helm repo add confluentinc https://packages.confluent.io/helm 2>/dev/null || true
	helm repo update
	helm upgrade --install cmf confluentinc/confluent-manager-for-apache-flink \
		--version "~$(CMF_VER)" \
		--namespace $(NAMESPACE) \
		--set cmf.sql.production=false
	@echo "→ Waiting for CMF pod to be ready (timeout 3m)..."
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=confluent-manager-for-apache-flink -n $(NAMESPACE) --timeout=180s
	@echo "✔ CMF v$(CMF_VER) installed."

.PHONY: cmf-env-create
cmf-env-create: ## Create a '$(CMF_ENV_NAME)' Flink environment in CMF pointing to the confluent namespace
	@echo "→ Creating Flink environment '$(CMF_ENV_NAME)' in CMF..."
	@kubectl port-forward -n $(NAMESPACE) svc/cmf-service 18080:80 >/dev/null 2>&1 & \
	PF_PID=$$!; \
	sleep 2; \
	HTTP_CODE=$$(curl -s -o /tmp/cmf-env-out.json -w "%{http_code}" -X POST \
		http://localhost:18080/cmf/api/v1/environments \
		-H "Content-Type: application/json" \
		-d "{\"name\":\"$(CMF_ENV_NAME)\",\"kubernetesNamespace\":\"$(NAMESPACE)\"}"); \
	kill $$PF_PID 2>/dev/null; \
	if [ "$$HTTP_CODE" = "200" ]; then \
		echo "✔ Flink environment '$(CMF_ENV_NAME)' created."; \
	elif [ "$$HTTP_CODE" = "409" ]; then \
		echo "→ Environment '$(CMF_ENV_NAME)' already exists, skipping."; \
	else \
		echo "✘ Failed (HTTP $$HTTP_CODE):"; cat /tmp/cmf-env-out.json; exit 1; \
	fi

.PHONY: cmf-status
cmf-status: ## Show CMF pod status and list registered Flink environments
	@echo "--- CMF Pod ---"
	@kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=confluent-manager-for-apache-flink
	@echo ""
	@echo "--- Flink Environments ---"
	@kubectl port-forward -n $(NAMESPACE) svc/cmf-service 18080:80 >/dev/null 2>&1 & \
	PF_PID=$$!; \
	sleep 2; \
	curl -sf http://localhost:18080/cmf/api/v1/environments \
		| python3 -m json.tool 2>/dev/null || echo "(no environments yet)"; \
	kill $$PF_PID 2>/dev/null; true

.PHONY: cmf-open
cmf-open: ## Port-forward CMF REST API to localhost:$(CMF_PORT)
	@echo "→ Forwarding CMF REST API to http://localhost:$(CMF_PORT)"
	@echo "   Press Ctrl+C to stop."
	@CURRENT_PGID=`ps -o "pgid=" -p $$PPID`; \
	trap "kill -TERM -$$CURRENT_PGID 2>/dev/null" EXIT INT TERM; \
	(sleep 2 && open http://localhost:$(CMF_PORT)/cmf/api/v1/environments) & \
	kubectl port-forward -n $(NAMESPACE) svc/cmf-service $(CMF_PORT):80

.PHONY: cmf-uninstall
cmf-uninstall: ## Uninstall CMF (safe to run even if not installed)
	@helm uninstall cmf -n $(NAMESPACE) --wait 2>/dev/null \
		&& echo "✔ CMF removed." \
		|| echo "→ cmf not installed, skipping."

.PHONY: cmf-proxy-logs
cmf-proxy-logs: ## Show logs from the cmf-proxy sidecar in the C3 pod (debug Flink tab connectivity)
	kubectl logs -n $(NAMESPACE) controlcenter-0 -c cmf-proxy --tail=50 -f

.PHONY: cmf-proxy-inject
cmf-proxy-inject: ## Patch C3 StatefulSet with socat sidecar (localhost:8080 → cmf-service:80) and pause CFK reconciliation
	@echo "→ Pausing CFK reconciliation for controlcenter..."
	kubectl annotate controlcenter controlcenter \
		platform.confluent.io/pause-reconciliation=true \
		-n $(NAMESPACE) --overwrite
	@echo "→ Patching StatefulSet to add cmf-proxy sidecar..."
	@printf '%s' '[{"op":"add","path":"/spec/template/spec/containers/-","value":{"name":"cmf-proxy","image":"alpine/socat:latest","args":["TCP-LISTEN:8080,fork,reuseaddr","TCP:cmf-service.confluent.svc.cluster.local:80"]}}]' \
		> /tmp/cmf-proxy-patch.json
	kubectl patch statefulset controlcenter -n $(NAMESPACE) --type=json --patch-file=/tmp/cmf-proxy-patch.json
	@echo "→ Deleting pod to restart from patched StatefulSet (avoids CFK rollout reconciliation)..."
	kubectl delete pod controlcenter-0 -n $(NAMESPACE)
	@echo "→ Waiting for pod to be ready (timeout 3m)..."
	kubectl wait --for=condition=ready pod/controlcenter-0 -n $(NAMESPACE) --timeout=180s
	@echo "✔ cmf-proxy sidecar injected. C3 localhost:8080 now proxies to cmf-service:80."
	@echo "   Verify with: make cmf-proxy-logs"

.PHONY: cmf-proxy-remove
cmf-proxy-remove: ## Remove the cmf-proxy sidecar and resume CFK reconciliation (will trigger C3 pod restart)
	@echo "→ Resuming CFK reconciliation for controlcenter..."
	kubectl annotate controlcenter controlcenter \
		platform.confluent.io/pause-reconciliation- \
		-n $(NAMESPACE) --overwrite 2>/dev/null || true
	@echo "→ Removing cmf-proxy container from StatefulSet..."
	@CONTAINERS=$$(kubectl get statefulset controlcenter -n $(NAMESPACE) \
		-o jsonpath='{.spec.template.spec.containers[*].name}'); \
	IDX=$$(echo "$$CONTAINERS" | tr ' ' '\n' | grep -n "cmf-proxy" | cut -d: -f1); \
	if [ -z "$$IDX" ]; then \
		echo "→ cmf-proxy not found in StatefulSet, skipping patch."; \
	else \
		IDX=$$((IDX - 1)); \
		kubectl patch statefulset controlcenter -n $(NAMESPACE) --type=json \
			-p="[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/$$IDX\"}]"; \
		echo "✔ cmf-proxy removed. CFK will reconcile and restart controlcenter-0."; \
	fi

# ------------------------------------------------------------------------------
# Phase 8: Kafka UI (Provectus)
# ------------------------------------------------------------------------------
.PHONY: kafka-ui-install
kafka-ui-install: ## Install Kafka UI and connect it to the Confluent Kafka cluster
	@echo "→ Adding Kafka UI Helm repo..."
	helm repo add kafka-ui https://provectus.github.io/kafka-ui-charts
	helm repo update
	@echo "→ Installing Kafka UI..."
	helm upgrade --install kafka-ui kafka-ui/kafka-ui \
		--namespace $(NAMESPACE) \
		--set yamlApplicationConfig.kafka.clusters[0].name="confluent" \
		--set yamlApplicationConfig.kafka.clusters[0].bootstrapServers="kafka:9071" \
		--set yamlApplicationConfig.kafka.clusters[0].schemaRegistry="http://schemaregistry:8081" \
		--set yamlApplicationConfig.kafka.clusters[0].kafkaConnect[0].name="connect" \
		--set yamlApplicationConfig.kafka.clusters[0].kafkaConnect[0].address="http://connect:8083" \
		--set yamlApplicationConfig.auth.type="DISABLED" \
		--set yamlApplicationConfig.management.health.ldap.enabled="false"
	@echo "✔ Kafka UI installed."

.PHONY: kafka-ui-status
kafka-ui-status: ## Check Kafka UI pod status
	kubectl get pods -n $(NAMESPACE) | grep kafka-ui

.PHONY: kafka-ui-open
kafka-ui-open: ## Port-forward Kafka UI and open it in your browser
	@echo "→ Forwarding Kafka UI to http://localhost:$(KAFKA_UI_PORT)"
	@echo "   Press Ctrl+C to stop."
	@CURRENT_PGID=`ps -o "pgid=" -p $$PPID`; 	trap "kill -TERM -$$CURRENT_PGID 2>/dev/null" EXIT INT TERM; 	(sleep 2 && open http://localhost:$(KAFKA_UI_PORT)) & 	kubectl port-forward -n $(NAMESPACE) svc/kafka-ui $(KAFKA_UI_PORT):80

.PHONY: kafka-ui-uninstall
kafka-ui-uninstall: ## Uninstall Kafka UI (safe to run even if not installed)
	@helm uninstall kafka-ui -n $(NAMESPACE) 2>/dev/null \
		&& echo "✔ Kafka UI removed." \
		|| echo "→ kafka-ui not installed, skipping."

# ------------------------------------------------------------------------------
# Phase 9: Build & Deploy Flink JARs
# ------------------------------------------------------------------------------
.PHONY: build-ptf-udf-row-driven
build-ptf-udf-row-driven: ## Build the ptf_udf_row_driven fat JAR (requires Gradle)
	@echo "→ Building ptf_udf_row_driven JAR..."
	@if [ ! -f examples/ptf_udf_row_driven/java/gradle/wrapper/gradle-wrapper.jar ]; then \
		echo "→ gradle-wrapper.jar missing — regenerating..."; \
		cd examples/ptf_udf_row_driven/java && gradle wrapper --gradle-version 9.4.1 -q; \
	fi
	cd examples/ptf_udf_row_driven/java && ./gradlew clean shadowJar -q
	@echo "✔ JAR built: $$(ls examples/ptf_udf_row_driven/java/app/build/libs/*.jar | head -1)"

.PHONY: deploy-cc-ptf-udf-row-driven
deploy-cc-ptf-udf-row-driven: build-ptf-udf-row-driven ## Build and deploy the ptf_udf_row_driven JAR to Confluent Cloud (ACTION, CONFLUENT_API_KEY, CONFLUENT_API_SECRET required)
	@echo "→ Deploying ptf_udf_row_driven to Confluent Cloud..."
	$(mkfile_dir)scripts/deploy-cc-ptf-udf-row-driven.sh create --confluent-api-key="$(CONFLUENT_API_KEY)" --confluent-api-secret="$(CONFLUENT_API_SECRET)"
	@echo "✔ Deployment complete."

.PHONY: teardown-cc-ptf-udf-row-driven
teardown-cc-ptf-udf-row-driven: ## Tear down the ptf_udf_row_driven deployment from Confluent Cloud (CONFLUENT_API_KEY, CONFLUENT_API_SECRET required)
	@echo "→ Tearing down ptf_udf_row_driven deployment from Confluent Cloud..."
	$(mkfile_dir)scripts/deploy-cc-ptf-udf-row-driven.sh destroy --confluent-api-key="$(CONFLUENT_API_KEY)" --confluent-api-secret="$(CONFLUENT_API_SECRET)"
	@echo "✔ Teardown complete."

.PHONY: deploy-cp-ptf-udf-row-driven
deploy-cp-ptf-udf-row-driven: build-ptf-udf-row-driven ## Build UDF JAR, copy to Flink pods, and execute SQL via Flink SQL Client
	@echo "→ Deploying ptf_udf_row_driven via Flink SQL..."
	$(mkfile_dir)scripts/deploy-cp-ptf-udf-row-driven.sh create \
		--namespace="$(NAMESPACE)" \
		--flink-cluster="$(FLINK_CLUSTER_NAME)"
	@echo "✔ SQL statements executed."

.PHONY: teardown-cp-ptf-udf-row-driven
teardown-cp-ptf-udf-row-driven: ## Tear down the ptf_udf_row_driven deployment
	@echo "→ Tearing down ptf_udf_row_driven..."
	$(mkfile_dir)scripts/deploy-cp-ptf-udf-row-driven.sh destroy \
		--namespace="$(NAMESPACE)" \
		--flink-cluster="$(FLINK_CLUSTER_NAME)"
	@echo "✔ Teardown complete."

.PHONY: produce-user-events-record
produce-user-events-record: ## Produce one sample user events to the 'user_events' topic using kafka-console-producer
	@kubectl exec -it kafka-0 -n confluent -- bash -c \
		"echo '{\"user_id\":\"alice\",\"event_type\":\"login\",\"payload\":\"web\"}' \
		| kafka-console-producer --bootstrap-server localhost:9071 --topic user_events"
	@echo "→ Produce one sample user events to the 'user_events' topic"

.PHONY: build-ptf-udf-timer-driven
build-ptf-udf-timer-driven: ## Build the ptf_udf_timer_driven fat JAR (requires Gradle)
	@echo "→ Building ptf_udf_timer_driven JAR..."
	@if [ ! -f examples/ptf_udf_timer_driven/java/gradle/wrapper/gradle-wrapper.jar ]; then \
		echo "→ gradle-wrapper.jar missing — regenerating..."; \
		cd examples/ptf_udf_timer_driven/java && gradle wrapper --gradle-version 9.4.1 -q; \
	fi
	cd examples/ptf_udf_timer_driven/java && ./gradlew clean shadowJar -q
	@echo "✔ JAR built: $$(ls examples/ptf_udf_timer_driven/java/app/build/libs/*.jar | head -1)"

.PHONY: deploy-cc-ptf-udf-timer-driven
deploy-cc-ptf-udf-timer-driven: build-ptf-udf-timer-driven ## Build and deploy the ptf_udf_timer_driven JAR to Confluent Cloud (CONFLUENT_API_KEY, CONFLUENT_API_SECRET required)
	@echo "→ Deploying ptf_udf_timer_driven to Confluent Cloud..."
	$(mkfile_dir)scripts/deploy-cc-ptf-udf-timer-driven.sh create --confluent-api-key="$(CONFLUENT_API_KEY)" --confluent-api-secret="$(CONFLUENT_API_SECRET)"
	@echo "✔ Deployment complete."

.PHONY: teardown-cc-ptf-udf-timer-driven
teardown-cc-ptf-udf-timer-driven: ## Tear down the ptf_udf_timer_driven deployment from Confluent Cloud (CONFLUENT_API_KEY, CONFLUENT_API_SECRET required)
	@echo "→ Tearing down ptf_udf_timer_driven deployment from Confluent Cloud..."
	$(mkfile_dir)scripts/deploy-cc-ptf-udf-timer-driven.sh destroy --confluent-api-key="$(CONFLUENT_API_KEY)" --confluent-api-secret="$(CONFLUENT_API_SECRET)"
	@echo "✔ Teardown complete."

.PHONY: deploy-cp-ptf-udf-timer-driven
deploy-cp-ptf-udf-timer-driven: build-ptf-udf-timer-driven ## Build timer-driven UDF JAR, copy to Flink pods, and execute SQL via Flink SQL Client
	@echo "→ Deploying ptf_udf_timer_driven via Flink SQL..."
	$(mkfile_dir)scripts/deploy-cp-ptf-udf-timer-driven.sh create \
		--namespace="$(NAMESPACE)" \
		--flink-cluster="$(FLINK_CLUSTER_NAME)"
	@echo "✔ SQL statements executed."

.PHONY: teardown-cp-ptf-udf-timer-driven
teardown-cp-ptf-udf-timer-driven: ## Tear down the ptf_udf_timer_driven deployment
	@echo "→ Tearing down ptf_udf_timer_driven..."
	$(mkfile_dir)scripts/deploy-cp-ptf-udf-timer-driven.sh destroy \
		--namespace="$(NAMESPACE)" \
		--flink-cluster="$(FLINK_CLUSTER_NAME)"
	@echo "✔ Teardown complete."

.PHONY: produce-user-activity-record
produce-user-activity-record: ## Produce one sample user activity event to the 'user_activity' topic using kafka-console-producer
	@kubectl exec -it kafka-0 -n confluent -- bash -c \
		"echo '{\"user_id\":\"alice\",\"event_type\":\"login\",\"payload\":\"web\",\"event_time\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}' \
		| kafka-console-producer --bootstrap-server localhost:9071 --topic user_activity"
	@echo "→ Produced one sample user activity event to the 'user_activity' topic"


# ------------------------------------------------------------------------------
# Composite workflows
# ------------------------------------------------------------------------------
.PHONY: cp-up
cp-up: check-prereqs minikube-start cp-core-up kafka-ui-install ## Full stack: Minikube → cp-core-up → kafka-ui (run 'make flink-up' separately for Flink)
	@echo ""
	@echo "✔ Confluent Platform and Kafka UI are deploying."
	@echo "  Run 'make cp-watch' to monitor pod startup."
	@echo "  Run 'make flink-up' to also deploy Apache Flink + CMF."

.PHONY: cp-core-up
cp-core-up: operator-install cp-deploy ## Phases 3-5: install CFK Operator → deploy CP → access Control Center
	@echo ""
	@echo "✔ Confluent Platform is deploying."
	@echo "  Run 'make cp-watch' to monitor pod startup."
	@echo "  Once all pods are Running, run 'make c3-open' to access Control Center."

.PHONY: flink-up
flink-up: flink-cert-manager flink-operator-install cmf-install cmf-env-create flink-deploy ## Install cert-manager → Confluent Flink Operator → CMF → Flink cluster
	@echo ""
	@echo "✔ Flink + CMF are deploying."
	@echo "  Run 'make flink-status' to check Flink pod status."
	@echo "  Run 'make cmf-status' to verify CMF and Flink environments."
	@echo "  Once running, open the Flink UI with 'make flink-ui'."

.PHONY: cp-down
cp-down: kafka-ui-uninstall cp-delete operator-uninstall ## Tear down Kafka UI, CP and Operator (keeps Minikube running)
	@echo "✔ Confluent Platform, Kafka UI and Operator removed."

.PHONY: flink-down
flink-down: flink-delete cmf-uninstall flink-operator-uninstall cert-manager-uninstall ## Tear down Flink cluster, CMF, operator, and cert-manager
	@echo "✔ Flink cluster, CMF, operator, and cert-manager removed."

.PHONY: cert-manager-uninstall
cert-manager-uninstall: ## Uninstall cert-manager (safe to run even if not installed)
	@kubectl delete -f https://github.com/jetstack/cert-manager/releases/download/$(CERT_MANAGER_VER)/cert-manager.yaml \
		--ignore-not-found=true 2>/dev/null \
		&& echo "✔ cert-manager removed." \
		|| echo "→ cert-manager not installed, skipping."

.PHONY: confluent-teardown
confluent-teardown: ## Full teardown: remove Flink, Kafka UI, CP, Operator, namespace, and stop Minikube
	@minikube status --format='{{.Host}}' 2>/dev/null | grep -q "Running" \
		|| (echo "✘ Minikube is not running — nothing to tear down." && exit 1)
	$(MAKE) flink-down
	$(MAKE) cp-down
	@echo "→ Deleting namespace '$(NAMESPACE)' and all remaining resources..."
	@kubectl delete namespace $(NAMESPACE) --ignore-not-found=true --wait=true 2>/dev/null \
		|| echo "→ Namespace $(NAMESPACE) not found, skipping."
	@echo "→ Verifying no pods remain in namespace '$(NAMESPACE)'..."
	@kubectl get pods -n $(NAMESPACE) 2>/dev/null || echo "→ Namespace gone — all clean."
	$(MAKE) minikube-stop
	@echo "✔ Full teardown complete."
