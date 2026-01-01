#!/bin/bash
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$REPO_ROOT/templates"
YAML_DIR="$REPO_ROOT/yaml"

# Source common functions
source "$SCRIPT_DIR/common.sh"

echo "=========================================="
echo "Deploying Mattermost with MinIO Storage"
echo "=========================================="

# Load and validate configuration
load_and_validate_config "$SCRIPT_DIR"

# Check if YAML directory exists and has required files
# If not, generate them (allows script to run standalone)
if [ ! -d "$YAML_DIR" ] || [ ! -f "$YAML_DIR/mattermost-installation-minio.yaml" ]; then
    echo "YAML files not found. Generating from templates..."
    if [ -x "$SCRIPT_DIR/generate-yaml.sh" ]; then
        "$SCRIPT_DIR/generate-yaml.sh"
    else
        echo "ERROR: generate-yaml.sh not found or not executable"
        exit 1
    fi
    echo ""
else
    echo "Using existing YAML files from $YAML_DIR"
    echo "  (Run 'make yaml' or 'make clean && make yaml' to regenerate)"
    echo ""
fi

# Ensure resource group exists
echo "Ensuring resource group exists..."
if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
    echo "Creating resource group: $RESOURCE_GROUP in $LOCATION"
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
fi

# Create AKS cluster
create_aks_cluster

# Create PostgreSQL database
create_postgresql

# Install cert-manager
install_cert_manager

# Install ALB Controller
install_alb_controller

# Create ALB infrastructure
create_alb_infrastructure

# Deploy MinIO Operator
echo ""
echo "Installing MinIO Operator..."
if kubectl get namespace minio-operator &>/dev/null; then
    print_warning "MinIO Operator already installed, skipping"
else
    # Use Kustomize to install MinIO Operator (official method per MinIO docs)
    kubectl kustomize "github.com/minio/operator?ref=$MINIO_OPERATOR_VERSION" | kubectl apply -f -

    echo "Waiting for MinIO Operator to be ready..."
    kubectl wait --for=condition=ready pod -l name=minio-operator -n minio-operator --timeout=300s
    print_success "MinIO Operator installed"
fi

# Deploy MinIO Tenant
echo ""
echo "Deploying MinIO Tenant..."
if kubectl get tenant minio-mattermost -n mattermost-minio &>/dev/null; then
    print_warning "MinIO tenant already exists, skipping"
else
    kubectl apply -k "$YAML_DIR/minio-tenant-kustomize"

    echo "Waiting for MinIO tenant to be ready (this may take several minutes)..."
    kubectl wait --for=jsonpath='{.status.currentState}'=Initialized tenant/minio-mattermost -n mattermost-minio --timeout=600s || echo "Tenant initialization taking longer than expected, continuing..."

    # Wait for MinIO pods
    echo "Waiting for MinIO pods to be ready..."
    kubectl wait --for=condition=ready pod -l v1.min.io/tenant=minio-mattermost -n mattermost-minio --timeout=600s
    print_success "MinIO tenant deployed"
fi

# Configure MinIO with mc
echo ""
echo "Configuring MinIO tenant..."
echo "Port-forwarding to MinIO service..."
kubectl -n mattermost-minio port-forward svc/minio 9000:80 &
PF_PID=$!

echo "Waiting for port-forward to be ready..."
for i in {1..30}; do
    if nc -z localhost 9000 2>/dev/null; then
        print_success "Port-forward established successfully"
        break
    fi
    if [ $i -eq 30 ]; then
        print_error "Port-forward failed to establish after 30 seconds"
        kill $PF_PID 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

echo "Configuring mc client..."
mc alias set minio-mattermost http://localhost:9000 "$MINIO_ADMIN_USER" "$MINIO_ADMIN_PASSWORD"

echo "Creating mattermost bucket..."
mc mb minio-mattermost/mattermost || echo "Bucket already exists"

echo "Creating service user..."
mc admin user add minio-mattermost "$MINIO_SERVICE_USER" "$MINIO_SERVICE_PASSWORD" || echo "User already exists"

echo "Creating and applying policy..."
mc admin policy create minio-mattermost mattermost-policy "$REPO_ROOT/minio-policy.json" || echo "Policy already exists"
mc admin policy attach minio-mattermost mattermost-policy --user="$MINIO_SERVICE_USER"

echo "Stopping port-forward..."
kill $PF_PID 2>/dev/null || true

print_success "MinIO configuration complete"

# Install Mattermost Operator
install_mattermost_operator

# Create Mattermost namespace and secrets
echo ""
echo "Creating Mattermost namespace and secrets..."
kubectl create namespace mattermost --dry-run=client -o yaml | kubectl apply -f -

# Apply secrets from pre-generated YAML
kubectl apply -f "$YAML_DIR/mattermost-secret-postgres.yaml"
kubectl apply -f "$YAML_DIR/mattermost-secret-minio.yaml"
if [ -f "$YAML_DIR/mattermost-secret-license.yaml" ]; then
    kubectl apply -f "$YAML_DIR/mattermost-secret-license.yaml"
fi

print_success "Secrets created"

# Create Gateway API resources (HTTP-only initially)
create_gateway_resources "$YAML_DIR" "$TEMPLATES_DIR"

# Configure DNS and wait for propagation
configure_dns_and_wait

# Provision TLS certificate
provision_tls_certificate "$YAML_DIR" "$TEMPLATES_DIR"

# Deploy Mattermost
echo ""
echo "Deploying Mattermost..."
kubectl apply -f "$YAML_DIR/mattermost-installation-minio.yaml"

echo ""
echo "Waiting for Mattermost pods to be ready (this may take several minutes)..."
kubectl -n mattermost wait --for=condition=ready pod -l app=mattermost --timeout=600s || echo "Mattermost deployment taking longer than expected, check status manually"

# Final status
echo ""
echo "=========================================="
echo "  Deployment Complete!"
echo "=========================================="
echo ""
echo "Mattermost URL: https://$DOMAIN"
echo ""
echo "To check deployment status:"
echo "  make status"
echo ""
echo "To view logs:"
echo "  make logs-mattermost"
echo "  make logs-minio"
echo ""
