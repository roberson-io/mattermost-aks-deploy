.PHONY: help env yaml deploy-minio deploy-nfs deploy-s3proxy teardown clean

# Load configuration from .env file if it exists
ifneq (,$(wildcard .env))
    include .env
    export
endif

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ''
	@echo 'Getting Started:'
	@echo '  1. Create .env with secrets:        make env'
	@echo '  2. Edit .env and set DOMAIN/EMAIL'
	@echo '  3. Deploy:                          make deploy-minio'
	@echo ''
	@echo 'Note: make deploy-minio automatically generates YAML files'
	@echo '      You can run "make yaml" separately to inspect generated files'
	@echo ''
	@echo 'Configuration is loaded from .env file'
	@echo 'See example.env for all available options'

env: ## Create .env file from example.env and generate secure secrets
	@if [ -f .env ]; then \
		echo "WARNING: .env file already exists!"; \
		read -p "Do you want to overwrite it? [y/N] " -n 1 -r; \
		echo; \
		if [[ ! $$REPLY =~ ^[Yy]$$ ]]; then \
			echo "Aborted. Keeping existing .env file."; \
			exit 0; \
		fi; \
	fi
	@if [ ! -f example.env ]; then \
		echo "ERROR: example.env not found!"; \
		exit 1; \
	fi
	@echo "Creating .env file with secure secrets..."
	@chmod +x scripts/generate-secrets.sh
	@./scripts/generate-secrets.sh
	@echo ""
	@echo "Next steps:"
	@echo "  1. Edit .env and update DOMAIN and EMAIL with your values"
	@echo "  2. Run: make deploy-minio"

yaml: ## Generate all YAML files from templates (requires .env)
	@if [ ! -f .env ]; then \
		echo "ERROR: .env file not found. Run 'make env' first."; \
		exit 1; \
	fi
	@echo "Generating YAML files from templates..."
	@chmod +x scripts/generate-yaml.sh
	@./scripts/generate-yaml.sh
	@echo "YAML files generated in yaml/ directory"

deploy-minio: yaml ## Deploy Mattermost with MinIO storage (creates cluster, PostgreSQL, etc.)
	@echo "=========================================="
	@echo "Deploying Mattermost with MinIO Storage"
	@echo "=========================================="
	@if [ ! -f minio-policy.json ]; then \
		echo "ERROR: minio-policy.json not found. Please ensure it exists in the current directory."; \
		exit 1; \
	fi
	@chmod +x scripts/deploy-minio.sh
	@./scripts/deploy-minio.sh
	@echo ""
	@echo "Deployment complete! Check PLAN.md for next steps."

deploy-nfs: ## Deploy Mattermost with NFS storage (requires cluster to exist)
	@echo "=========================================="
	@echo "Deploying Mattermost with NFS Storage"
	@echo "=========================================="
	@chmod +x scripts/deploy-nfs.sh
	@./scripts/deploy-nfs.sh
	@echo ""
	@echo "Deployment complete! Check PLAN.md for comparison notes."

deploy-s3proxy: ## Deploy Mattermost with s3proxy + Azure Blob storage (requires cluster to exist)
	@echo "=========================================="
	@echo "Deploying Mattermost with s3proxy Storage"
	@echo "=========================================="
	@chmod +x scripts/deploy-s3proxy.sh
	@./scripts/deploy-s3proxy.sh
	@echo ""
	@echo "Deployment complete! Check PLAN.md for comparison notes."

teardown: ## Delete the entire AKS cluster and all resources
	@if [ ! -f .env ]; then \
		echo "ERROR: .env file not found. Cannot determine resource group to delete."; \
		exit 1; \
	fi
	@echo "=========================================="
	@echo "Tearing down AKS cluster and resources"
	@echo "=========================================="
	@echo "WARNING: This will delete:"
	@echo "  - AKS cluster: $(CLUSTER_NAME)"
	@echo "  - PostgreSQL server: $(POSTGRES_SERVER)"
	@echo "  - All associated resources in: $(RESOURCE_GROUP)"
	@echo ""
	@read -p "Are you sure you want to continue? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo "Deleting resource group $(RESOURCE_GROUP)..."; \
		az group delete --name $(RESOURCE_GROUP) --yes --no-wait; \
		echo "Deletion initiated. This will complete in the background."; \
		echo "To check status: az group show --name $(RESOURCE_GROUP)"; \
	else \
		echo "Teardown cancelled."; \
	fi

clean: ## Remove generated YAML files and directories
	@echo "Cleaning up generated files..."
	@rm -rf yaml/
	@echo "Cleanup complete."

status: ## Show status of all deployments
	@if [ ! -f .env ]; then \
		echo "ERROR: .env file not found. Run 'make help' for setup instructions."; \
		exit 1; \
	fi
	@echo "=========================================="
	@echo "Deployment Status"
	@echo "=========================================="
	@echo ""
	@echo "AKS Cluster:"
	@az aks show --resource-group $(RESOURCE_GROUP) --name $(CLUSTER_NAME) --query "{Name:name,Status:provisioningState,Location:location,K8sVersion:kubernetesVersion}" -o table 2>/dev/null || echo "Not found"
	@echo ""
	@echo "PostgreSQL Server:"
	@az postgres flexible-server show --resource-group $(RESOURCE_GROUP) --name $(POSTGRES_SERVER) --query "{Name:name,Status:state,Version:version}" -o table 2>/dev/null || echo "Not found"
	@echo ""
	@echo "Kubernetes Resources:"
	@if kubectl cluster-info &>/dev/null; then \
		echo "Gateway:"; \
		kubectl get gateway -n mattermost 2>/dev/null || echo "  Not deployed"; \
		echo ""; \
		echo "Mattermost:"; \
		kubectl get mm -n mattermost 2>/dev/null || echo "  Not deployed"; \
		echo ""; \
		echo "MinIO:"; \
		kubectl get tenant -n mattermost-minio 2>/dev/null || echo "  Not deployed"; \
		echo ""; \
		echo "s3proxy:"; \
		kubectl get pods -n s3proxy 2>/dev/null || echo "  Not deployed"; \
		echo ""; \
		echo "NFS PVC:"; \
		kubectl get pvc -n mattermost 2>/dev/null || echo "  Not deployed"; \
	else \
		echo "Cannot connect to Kubernetes cluster"; \
	fi

test-minio: ## Test MinIO deployment (requires deploy-minio to be run first)
	@echo "Testing MinIO deployment..."
	@kubectl get tenant -n mattermost-minio
	@kubectl get pods -n mattermost-minio
	@kubectl get mm -n mattermost

test-nfs: ## Test NFS deployment (requires deploy-nfs to be run first)
	@echo "Testing NFS deployment..."
	@kubectl get pvc -n mattermost
	@kubectl get mm -n mattermost
	@kubectl exec -n mattermost deployment/mattermost -- df -h /mattermost/data

test-s3proxy: ## Test s3proxy deployment (requires deploy-s3proxy to be run first)
	@echo "Testing s3proxy deployment..."
	@kubectl get pods -n s3proxy
	@kubectl logs -n s3proxy deployment/s3proxy --tail=20
	@kubectl get mm -n mattermost

logs-mattermost: ## Show Mattermost logs
	@kubectl logs -n mattermost deployment/mattermost --tail=50 -f

logs-minio: ## Show MinIO logs
	@kubectl logs -n mattermost-minio -l v1.min.io/tenant=minio-mattermost --tail=50

logs-s3proxy: ## Show s3proxy logs
	@kubectl logs -n s3proxy deployment/s3proxy --tail=50 -f

gateway-ip: ## Get the Gateway external IP address
	@kubectl get gateway mattermost-gateway -n mattermost -o jsonpath='{.status.addresses[0].value}' 2>/dev/null && echo "" || echo "Gateway not ready yet"

trivy-config: ## Scan YAML configurations for security issues
	@echo "=== Scanning YAML configurations ==="
	@if [ ! -d yaml/ ]; then \
		echo "ERROR: yaml/ directory not found. Run 'make yaml' first."; \
		exit 1; \
	fi
	@trivy config --severity HIGH,CRITICAL yaml/

trivy-images: ## Scan container images for vulnerabilities
	@echo "=== Scanning container images ==="
	@if [ ! -f .env ]; then \
		echo "ERROR: .env file not found. Run 'make env' first."; \
		exit 1; \
	fi
	@echo "Scanning Chainguard MinIO image..."
	@trivy image --severity HIGH,CRITICAL $(MINIO_IMAGE)
	@echo ""
	@echo "Scanning Mattermost image..."
	@trivy image --severity HIGH,CRITICAL mattermost/mattermost-enterprise-edition:$(MATTERMOST_VERSION)
	@echo ""
	@echo "Scanning MinIO Operator..."
	@trivy image --severity HIGH,CRITICAL minio/operator:$(MINIO_OPERATOR_VERSION)

trivy-cluster: ## Scan live Kubernetes cluster for security issues
	@echo "=== Scanning live Kubernetes cluster ==="
	@if ! kubectl cluster-info &>/dev/null; then \
		echo "ERROR: Cannot connect to Kubernetes cluster"; \
		exit 1; \
	fi
	@echo "Scanning mattermost namespace..."
	@trivy k8s --include-namespaces mattermost --report summary || echo "Namespace not found or no resources"
	@echo ""
	@echo "Scanning mattermost-minio namespace..."
	@trivy k8s --include-namespaces mattermost-minio --report summary || echo "Namespace not found or no resources"
	@echo ""
	@echo "Scanning minio-operator namespace..."
	@trivy k8s --include-namespaces minio-operator --report summary || echo "Namespace not found or no resources"

trivy-report: ## Generate comprehensive security reports in JSON format
	@echo "=== Generating comprehensive security reports ==="
	@if [ ! -f .env ]; then \
		echo "ERROR: .env file not found. Run 'make env' first."; \
		exit 1; \
	fi
	@if [ ! -d yaml/ ]; then \
		echo "ERROR: yaml/ directory not found. Run 'make yaml' first."; \
		exit 1; \
	fi
	@mkdir -p reports
	@echo "Generating config scan report..."
	@trivy config --format json --output reports/config-scan.json yaml/
	@echo "Generating MinIO image scan report..."
	@trivy image --format json --output reports/minio-image-scan.json $(MINIO_IMAGE)
	@echo "Generating Mattermost image scan report..."
	@trivy image --format json --output reports/mattermost-image-scan.json mattermost/mattermost-enterprise-edition:$(MATTERMOST_VERSION)
	@if kubectl cluster-info &>/dev/null; then \
		echo "Generating cluster scan reports..."; \
		trivy k8s --include-namespaces mattermost --format json --output reports/cluster-mattermost-scan.json 2>/dev/null || echo "  Mattermost namespace not found"; \
		trivy k8s --include-namespaces mattermost-minio --format json --output reports/cluster-minio-scan.json 2>/dev/null || echo "  MinIO namespace not found"; \
		trivy k8s --include-namespaces minio-operator --format json --output reports/cluster-operator-scan.json 2>/dev/null || echo "  MinIO operator namespace not found"; \
	else \
		echo "Skipping cluster scans (not connected to cluster)"; \
	fi
	@echo ""
	@echo "Reports saved to reports/ directory:"
	@ls -lh reports/

trivy-full: trivy-config trivy-images trivy-cluster ## Run all Trivy security scans
	@echo ""
	@echo "=== Full security scan complete ==="
