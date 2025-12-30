#!/bin/bash
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$REPO_ROOT/templates"
YAML_DIR="$REPO_ROOT/yaml"

echo "=========================================="
echo "Deploying Mattermost with MinIO Storage"
echo "=========================================="

# Load environment variables from .env file
if [ ! -f "$REPO_ROOT/.env" ]; then
    echo "ERROR: .env file not found!"
    echo ""
    echo "Please create a .env file with your configuration:"
    echo "  Run: make env"
    echo "  Then edit .env and update DOMAIN and EMAIL"
    echo ""
    exit 1
fi

echo "Loading configuration from .env file..."
source "$REPO_ROOT/.env"

# Set defaults for optional variables
RESOURCE_GROUP="${RESOURCE_GROUP:-mattermost-test-rg}"
CLUSTER_NAME="${CLUSTER_NAME:-mattermost-test-aks}"
LOCATION="${LOCATION:-eastus}"
NODE_COUNT="${NODE_COUNT:-3}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_D4s_v4}"
POSTGRES_SERVER="${POSTGRES_SERVER:-mattermost-postgres}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-mmadmin}"
POSTGRES_TIER="${POSTGRES_TIER:-MemoryOptimized}"
POSTGRES_SKU="${POSTGRES_SKU:-Standard_E2ds_v4}"
POSTGRES_STORAGE_SIZE="${POSTGRES_STORAGE_SIZE:-128}"
POSTGRES_VERSION="${POSTGRES_VERSION:-18}"
POSTGRES_PUBLIC_ACCESS="${POSTGRES_PUBLIC_ACCESS:-0.0.0.0}"
MINIO_OPERATOR_VERSION="${MINIO_OPERATOR_VERSION:-v7.1.1}"
MINIO_IMAGE="${MINIO_IMAGE:-minio/minio:RELEASE.2025-10-15T17-29-55Z}"
MINIO_ADMIN_USER="${MINIO_ADMIN_USER:-admin}"
MINIO_SERVICE_USER="${MINIO_SERVICE_USER:-mattermost}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.19.2}"
DOMAIN="${DOMAIN:-mattermost.example.com}"
EMAIL="${EMAIL:-admin@example.com}"
MATTERMOST_VERSION="${MATTERMOST_VERSION:-11.2.1}"
MATTERMOST_SIZE="${MATTERMOST_SIZE:-1000users}"

# Validate required secrets are not placeholder values
if [[ "$POSTGRES_PASSWORD" == *"CHANGE_ME"* ]] || \
   [[ "$MINIO_ADMIN_PASSWORD" == *"CHANGE_ME"* ]] || \
   [[ "$MINIO_SERVICE_PASSWORD" == *"CHANGE_ME"* ]]; then
    echo "ERROR: Placeholder passwords detected in .env file!"
    echo ""
    echo "Please generate secure secrets by running:"
    echo "  make env"
    echo ""
    exit 1
fi

# Validate license file is provided and exists
if [ -z "$LICENSE_FILE" ]; then
    echo "ERROR: LICENSE_FILE is not set in .env file!"
    echo ""
    echo "A Mattermost license file is required for this deployment."
    echo "Please set LICENSE_FILE in .env to point to your license file:"
    echo "  LICENSE_FILE=./license.mattermost"
    echo ""
    exit 1
fi

if [ ! -f "$LICENSE_FILE" ]; then
    echo "ERROR: License file not found: $LICENSE_FILE"
    echo ""
    echo "Please ensure the license file exists at the specified path."
    echo ""
    exit 1
fi

if [ ! -s "$LICENSE_FILE" ]; then
    echo "ERROR: License file is empty: $LICENSE_FILE"
    echo ""
    echo "Please provide a valid Mattermost license file."
    echo ""
    exit 1
fi

echo "Using configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Cluster Name: $CLUSTER_NAME"
echo "  Location: $LOCATION"
echo "  Domain: $DOMAIN"
echo ""

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

# Create resource group if it doesn't exist
echo "Checking resource group..."
if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
    echo "Creating resource group..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
else
    echo "Resource group already exists"
fi

# Create AKS cluster if it doesn't exist
echo ""
echo "Checking AKS cluster..."
if ! az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" &>/dev/null; then
    echo "Creating AKS cluster (this will take 5-10 minutes)..."
    az aks create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CLUSTER_NAME" \
        --enable-managed-identity \
        --node-count "$NODE_COUNT" \
        --node-vm-size "$NODE_VM_SIZE" \
        --generate-ssh-keys \
        --network-plugin azure \
        --network-policy calico \
        --enable-blob-driver \
        --enable-workload-identity \
        --enable-oidc-issuer \
        --location "$LOCATION"

    echo "Getting AKS credentials..."
    az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --admin --overwrite-existing
else
    echo "AKS cluster already exists, skipping creation"
    az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --admin --overwrite-existing
fi

# Create PostgreSQL if it doesn't exist
echo ""
echo "Checking PostgreSQL database..."
if ! az postgres flexible-server show --resource-group "$RESOURCE_GROUP" --name "$POSTGRES_SERVER" &>/dev/null; then
    echo "Creating PostgreSQL flexible server..."
    az postgres flexible-server create \
        --name "$POSTGRES_SERVER" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --admin-user "$POSTGRES_ADMIN_USER" \
        --admin-password "$POSTGRES_PASSWORD" \
        --tier "$POSTGRES_TIER" \
        --sku-name "$POSTGRES_SKU" \
        --storage-size "$POSTGRES_STORAGE_SIZE" \
        --public-access "$POSTGRES_PUBLIC_ACCESS" \
        --version "$POSTGRES_VERSION"

    echo "Waiting for PostgreSQL to be ready..."
    # Wait up to 3 minutes for the server to be fully ready
    MAX_RETRIES=18
    RETRY_COUNT=0
    until az postgres flexible-server show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$POSTGRES_SERVER" \
        --query "state" -o tsv 2>/dev/null | grep -q "Ready"; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            echo "ERROR: PostgreSQL server did not become ready in time"
            exit 1
        fi
        echo "Waiting for server to be ready (attempt $RETRY_COUNT/$MAX_RETRIES)..."
        sleep 10
    done
    echo "PostgreSQL server is ready!"

    echo "Creating $POSTGRES_DB database..."
    az postgres flexible-server db create \
        --resource-group "$RESOURCE_GROUP" \
        --server-name "$POSTGRES_SERVER" \
        --database-name "$POSTGRES_DB"
else
    echo "PostgreSQL server already exists, skipping creation"
fi

# Get connection string
POSTGRES_HOST=$(az postgres flexible-server show --resource-group "$RESOURCE_GROUP" --name "$POSTGRES_SERVER" --query "fullyQualifiedDomainName" -o tsv)
CONNECTION_STRING="postgres://$POSTGRES_ADMIN_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST/mattermost?sslmode=require"
export CONNECTION_STRING_BASE64=$(echo -n "$CONNECTION_STRING" | base64)

# Install cert-manager with Gateway API support
echo ""
echo "Installing cert-manager with Gateway API support..."
if ! kubectl get namespace cert-manager &>/dev/null; then
    # Add cert-manager Helm repository
    helm repo add jetstack https://charts.jetstack.io --force-update

    # Install cert-manager with Gateway API feature gate enabled
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version "$CERT_MANAGER_VERSION" \
        --set crds.enabled=true \
        --set "extraArgs={--feature-gates=ExperimentalGatewayAPISupport=true}"

    echo "Waiting for cert-manager pods to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s
else
    echo "cert-manager already installed, skipping"
fi

# Install ALB Controller
echo ""
echo "Installing Azure Application Gateway for Containers (ALB Controller)..."
if ! kubectl get namespace azure-alb-system &>/dev/null; then
    echo "Creating managed identity for ALB..."
    az identity create --resource-group "$RESOURCE_GROUP" --name alb-controller-identity --location "$LOCATION"

    IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name alb-controller-identity --query principalId -o tsv)
    IDENTITY_CLIENT_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name alb-controller-identity --query clientId -o tsv)

    echo "Assigning permissions to managed identity..."
    az role assignment create \
        --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP" \
        --role "AppGw for Containers Configuration Manager"

    echo "Creating federated identity credential for workload identity..."
    AKS_OIDC_ISSUER=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --query oidcIssuerProfile.issuerUrl -o tsv)

    # Check if federated credential already exists
    if ! az identity federated-credential show \
        --name alb-controller-federated-credential \
        --identity-name alb-controller-identity \
        --resource-group "$RESOURCE_GROUP" &>/dev/null; then

        az identity federated-credential create \
            --name alb-controller-federated-credential \
            --identity-name alb-controller-identity \
            --resource-group "$RESOURCE_GROUP" \
            --issuer "$AKS_OIDC_ISSUER" \
            --subject system:serviceaccount:azure-alb-system:alb-controller-sa \
            --audience api://AzureADTokenExchange

        echo "Federated identity credential created successfully"
    else
        echo "Federated identity credential already exists, skipping"
    fi

    echo "Installing ALB Controller via Helm..."
    helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller \
        --namespace azure-alb-system \
        --create-namespace \
        --set albController.namespace=azure-alb-system \
        --set albController.podIdentity.clientID="$IDENTITY_CLIENT_ID"

    echo "Waiting for ALB Controller to be ready..."
    kubectl wait --for=condition=ready pod -l app=alb-controller -n azure-alb-system --timeout=300s
else
    echo "ALB Controller already installed, skipping"
fi

# Create Application Gateway for Containers resources
echo ""
echo "Creating Application Gateway for Containers resources..."

# Get subscription ID
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Set ALB resource names
ALB_NAME="${CLUSTER_NAME}-alb"
ALB_FRONTEND_NAME="frontend-mattermost"
ALB_ASSOCIATION_NAME="association-mattermost"

# Check if Application Gateway for Containers already exists
if ! az network alb show --resource-group "$RESOURCE_GROUP" --name "$ALB_NAME" &>/dev/null; then
    echo "Creating Application Gateway for Containers..."
    az network alb create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$ALB_NAME" \
        --location "$LOCATION"

    echo "Creating ALB frontend..."
    az network alb frontend create \
        --resource-group "$RESOURCE_GROUP" \
        --alb-name "$ALB_NAME" \
        --name "$ALB_FRONTEND_NAME"

    # Get the node resource group and VNet details
    NODE_RESOURCE_GROUP=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --query nodeResourceGroup -o tsv)

    # Get the VNet name from the node resource group
    VNET_NAME=$(az network vnet list --resource-group "$NODE_RESOURCE_GROUP" --query "[0].name" -o tsv)

    # Get the first subnet ID
    SUBNET_ID=$(az network vnet subnet list \
        --resource-group "$NODE_RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --query "[0].id" -o tsv)

    SUBNET_NAME=$(az network vnet subnet list \
        --resource-group "$NODE_RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --query "[0].name" -o tsv)

    # Delegate the subnet to Traffic Controller
    echo "Delegating subnet to Microsoft.ServiceNetworking/trafficControllers..."
    az network vnet subnet update \
        --resource-group "$NODE_RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$SUBNET_NAME" \
        --delegations Microsoft.ServiceNetworking/trafficControllers

    ALB_SUBNET_ID="$SUBNET_ID"

    echo "Creating ALB association with subnet..."
    az network alb association create \
        --resource-group "$RESOURCE_GROUP" \
        --alb-name "$ALB_NAME" \
        --name "$ALB_ASSOCIATION_NAME" \
        --subnet "$ALB_SUBNET_ID"

    echo "Application Gateway for Containers created successfully"
else
    echo "Application Gateway for Containers already exists, skipping"
fi

# Get the ALB resource ID for use in Gateway annotation
export ALB_ID=$(az network alb show --resource-group "$RESOURCE_GROUP" --name "$ALB_NAME" --query id -o tsv)
echo "ALB Resource ID: $ALB_ID"

# Wait for ALB to be provisioned
echo "Waiting for Application Gateway for Containers to be ready..."
RETRY_COUNT=0
MAX_RETRIES=30
until az network alb show --resource-group "$RESOURCE_GROUP" --name "$ALB_NAME" --query "provisioningState" -o tsv 2>/dev/null | grep -q "Succeeded"; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "WARNING: ALB provisioning taking longer than expected, continuing anyway..."
        break
    fi
    echo "Waiting for ALB provisioning (attempt $RETRY_COUNT/$MAX_RETRIES)..."
    sleep 10
done
echo "Application Gateway for Containers is ready!"

# Install MinIO Operator
echo ""
echo "Installing MinIO Operator..."
if ! kubectl get namespace minio-operator &>/dev/null; then
    # Use Kustomize to install MinIO Operator (official method per MinIO docs)
    kubectl kustomize "github.com/minio/operator?ref=$MINIO_OPERATOR_VERSION" | kubectl apply -f -
    echo "Waiting for MinIO Operator to be ready..."
    kubectl wait --for=condition=ready pod -l name=minio-operator -n minio-operator --timeout=300s
else
    echo "MinIO Operator already installed, skipping"
fi

# Deploy MinIO Tenant
echo ""
echo "Deploying MinIO Tenant..."

# Check if tenant already exists
if kubectl get tenant minio-mattermost -n mattermost-minio &>/dev/null; then
    echo "MinIO Tenant already exists, checking pod status..."
    # Check if pods are ready
    if kubectl wait --for=condition=ready pod -l v1.min.io/tenant=minio-mattermost -n mattermost-minio --timeout=10s &>/dev/null; then
        echo "MinIO Tenant pods are already running and ready"
    else
        echo "MinIO Tenant exists but pods are not ready, waiting..."
        kubectl wait --for=condition=ready pod -l v1.min.io/tenant=minio-mattermost -n mattermost-minio --timeout=600s
    fi
else
    echo "Creating MinIO Tenant..."
    kubectl apply -k "$YAML_DIR/minio-tenant-kustomize/"

    echo "Waiting for MinIO tenant to be ready (this may take a few minutes)..."
    # Wait for the StatefulSet to be created by the operator
    echo "Waiting for MinIO StatefulSet to be created..."
    RETRY_COUNT=0
    MAX_RETRIES=60
    until kubectl get statefulset -n mattermost-minio -l v1.min.io/tenant=minio-mattermost -o name 2>/dev/null | grep -q statefulset; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            echo "ERROR: MinIO StatefulSet was not created in time"
            exit 1
        fi
        echo "Waiting for StatefulSet to be created (attempt $RETRY_COUNT/$MAX_RETRIES)..."
        sleep 5
    done
    echo "StatefulSet created, waiting for pods to be ready..."
    kubectl wait --for=condition=ready pod -l v1.min.io/tenant=minio-mattermost -n mattermost-minio --timeout=600s
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
        echo "Port-forward established successfully"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "ERROR: Port-forward failed to establish after 30 seconds"
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

# Deploy Mattermost Operator
echo ""
echo "Installing Mattermost Operator..."
if ! kubectl get namespace mattermost-operator &>/dev/null; then
    # Add Mattermost Helm repository
    helm repo add mattermost https://helm.mattermost.com
    helm repo update

    # Create namespace
    kubectl create ns mattermost-operator

    # Install Mattermost Operator via Helm
    helm install mattermost-operator mattermost/mattermost-operator -n mattermost-operator

    echo "Waiting for Mattermost Operator to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mattermost-operator -n mattermost-operator --timeout=300s
else
    echo "Mattermost Operator already installed, skipping"
fi

# Create Mattermost namespace and secrets using templates
echo ""
echo "Creating Mattermost namespace and secrets..."
kubectl create namespace mattermost --dry-run=client -o yaml | kubectl apply -f -

# Generate postgres secret
envsubst < "$TEMPLATES_DIR/mattermost-secret-postgres.yaml.tmpl" > "$YAML_DIR/mattermost-secret-postgres.yaml"
kubectl apply -f "$YAML_DIR/mattermost-secret-postgres.yaml"

# Generate MinIO secret
export MINIO_ACCESS_KEY_BASE64=$(echo -n "$MINIO_SERVICE_USER" | base64)
export MINIO_SECRET_KEY_BASE64=$(echo -n "$MINIO_SERVICE_PASSWORD" | base64)
envsubst < "$TEMPLATES_DIR/mattermost-secret-minio.yaml.tmpl" > "$YAML_DIR/mattermost-secret-minio.yaml"
kubectl apply -f "$YAML_DIR/mattermost-secret-minio.yaml"

# Create license secret if LICENSE_FILE is provided
if [ -n "$LICENSE_FILE" ] && [ -f "$LICENSE_FILE" ]; then
    echo "Creating license secret from $LICENSE_FILE..."
    LICENSE_CONTENT=$(cat "$LICENSE_FILE")
    export LICENSE_CONTENT_BASE64=$(echo -n "$LICENSE_CONTENT" | base64)

    envsubst < "$TEMPLATES_DIR/mattermost-secret-license.yaml.tmpl" > "$YAML_DIR/mattermost-secret-license.yaml"
    kubectl apply -f "$YAML_DIR/mattermost-secret-license.yaml"
    echo "License secret created successfully"
else
    echo "No license file provided, skipping license configuration"
fi

# Create Gateway API resources
echo ""
echo "Deploying Gateway API resources..."

# Apply Gateway class and cluster issuer (idempotent with kubectl apply)
kubectl apply -f "$YAML_DIR/gateway-class.yaml"
kubectl apply -f "$YAML_DIR/cluster-issuer.yaml"

# Check if Gateway exists
if kubectl get gateway mattermost-gateway -n mattermost &>/dev/null; then
    echo "Gateway already exists, checking status..."
else
    echo "Creating Gateway (HTTP only initially)..."
    # Generate and apply gateway from HTTP template
    export ALB_ID
    envsubst < "$TEMPLATES_DIR/mattermost-gateway-http.yaml.tmpl" > "$YAML_DIR/mattermost-gateway.yaml"
    kubectl apply -f "$YAML_DIR/mattermost-gateway.yaml"
fi

# Wait for Gateway to be Programmed
echo "Waiting for Gateway to be Programmed..."
for i in {1..30}; do
    STATUS=$(kubectl get gateway mattermost-gateway -n mattermost -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
    if [ "$STATUS" = "True" ]; then
        echo "Gateway is Programmed"
        break
    fi
    echo "Waiting for Gateway... ($i/30)"
    sleep 10
done

# Create ClusterIP service and HTTPRoute (idempotent with kubectl apply)
echo "Applying Gateway service and HTTPRoute..."
kubectl apply -f "$YAML_DIR/mattermost-gateway-svc.yaml"
export DOMAIN
envsubst < "$TEMPLATES_DIR/mattermost-httproute.yaml.tmpl" > "$YAML_DIR/mattermost-httproute.yaml"
kubectl apply -f "$YAML_DIR/mattermost-httproute.yaml"

# Wait for Gateway IP and prompt for DNS update
echo ""
echo "Waiting for Gateway to get external IP..."
GATEWAY_FQDN=""
for i in {1..30}; do
    GATEWAY_FQDN=$(kubectl get gateway mattermost-gateway -n mattermost -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
    if [ -n "$GATEWAY_FQDN" ]; then
        break
    fi
    echo "Waiting for Gateway IP... ($i/30)"
    sleep 10
done

if [ -z "$GATEWAY_FQDN" ]; then
    echo "ERROR: Gateway did not get an external IP within 5 minutes"
    exit 1
fi

# Resolve FQDN to IP if needed
GATEWAY_IP=$(dig +short "$GATEWAY_FQDN" | head -1)
if [ -z "$GATEWAY_IP" ]; then
    GATEWAY_IP="$GATEWAY_FQDN"
fi

echo ""
echo "=============================================="
echo "  DNS Configuration Required"
echo "=============================================="
echo ""
echo "Gateway FQDN: $GATEWAY_FQDN"
echo "Gateway IP:   $GATEWAY_IP"
echo ""
echo "Configure DNS for your domain ($DOMAIN) using ONE of these options:"
echo ""
echo "Option 1 - CNAME Record:"
echo "  Type: CNAME"
echo "  Name: $DOMAIN"
echo "  Value: $GATEWAY_FQDN"
echo ""
echo "Option 2 - A Record:"
echo "  Type: A"
echo "  Name: $DOMAIN"
echo "  Value: $GATEWAY_IP"
echo ""
echo "Note: The TLS certificate (Let's Encrypt) requires the domain"
echo "      to resolve to the Gateway IP for HTTP-01 validation."
echo ""

# Check if dig is available
if ! command -v dig &> /dev/null; then
    echo "WARNING: 'dig' command not found. Please install dnsutils (apt) or bind-tools (yum)"
    echo "Continuing without DNS verification..."
    read -p "Press ENTER after you have updated DNS (or Ctrl+C to cancel)..."
else
    # DNS Verification Loop
    echo "Checking DNS propagation (using DNS server: ${DNS_SERVER:-8.8.8.8})..."
    DNS_READY=false
    for i in {1..30}; do
        RESOLVED_IP=$(dig +short "$DOMAIN" @${DNS_SERVER:-8.8.8.8} | grep -E '^[0-9.]+$' | head -1)

        if [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" = "$GATEWAY_IP" ]; then
            echo "✓ DNS propagated successfully! $DOMAIN resolves to $GATEWAY_IP"
            DNS_READY=true
            break
        fi

        if [ -n "$RESOLVED_IP" ]; then
            echo "DNS not yet propagated: $DOMAIN -> $RESOLVED_IP (expected $GATEWAY_IP) - attempt $i/30"
        else
            echo "DNS not yet configured: $DOMAIN has no DNS record - attempt $i/30"
        fi

        sleep 10
    done

    if [ "$DNS_READY" = false ]; then
        echo ""
        echo "WARNING: DNS did not propagate within 5 minutes"
        echo "Please verify your DNS configuration and wait for propagation"
        read -p "Press ENTER to continue anyway (or Ctrl+C to cancel)..."
    fi
fi

# Create TLS Certificate for Gateway using template
echo ""
echo "Creating TLS certificate for Gateway..."

# Check if certificate exists
CERT_EXISTS=false
if kubectl get certificate mattermost-tls-cert -n mattermost &>/dev/null; then
    CERT_EXISTS=true
    CERT_READY=$(kubectl get certificate mattermost-tls-cert -n mattermost -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$CERT_READY" = "True" ]; then
        echo "Certificate already exists and is ready"
    else
        echo "Certificate exists but is not ready, checking ACME challenge setup..."
    fi
else
    echo "Creating certificate resource..."
    envsubst < "$TEMPLATES_DIR/mattermost-certificate.yaml.tmpl" | kubectl apply -f -
    echo "Certificate resource created"
fi

# If certificate is not ready, handle ACME challenge
if [ "$CERT_EXISTS" = "false" ] || [ "$CERT_READY" != "True" ]; then
    # Wait for cert-manager to create the ACME solver service
    echo "Waiting for ACME solver service to be created..."
    SOLVER_SVC=""
    for i in {1..30}; do
        SOLVER_SVC=$(kubectl get svc -n mattermost -l acme.cert-manager.io/http01-solver=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -n "$SOLVER_SVC" ]; then
            echo "Found ACME solver service: $SOLVER_SVC"
            break
        fi
        echo "Waiting for solver service... ($i/30)"
        sleep 5
    done

    if [ -n "$SOLVER_SVC" ]; then
        # Create HTTPRoute for ACME challenge (Azure ALB doesn't process Ingress resources)
        echo "Creating HTTPRoute for ACME challenge..."
        export SOLVER_SVC
        envsubst < "$TEMPLATES_DIR/mattermost-acme-challenge.yaml.tmpl" > "$YAML_DIR/mattermost-acme-challenge.yaml"
        kubectl apply -f "$YAML_DIR/mattermost-acme-challenge.yaml"
        echo "ACME challenge HTTPRoute created"
    else
        echo "WARNING: ACME solver service not found. Certificate may fail to issue."
    fi

    echo "Waiting for certificate to be issued..."
    kubectl wait --for=condition=ready certificate mattermost-tls-cert -n mattermost --timeout=300s || echo "Certificate issuance may take a few minutes to complete"

    # Clean up ACME HTTPRoute after certificate is issued
    kubectl delete httproute acme-challenge -n mattermost 2>/dev/null || true
fi

# Verify TLS secret exists before adding HTTPS listener
echo ""
echo "Verifying TLS secret exists..."
if kubectl get secret mattermost-tls-cert -n mattermost &>/dev/null; then
    echo "TLS secret exists, adding HTTPS listener to Gateway..."
    envsubst < "$TEMPLATES_DIR/mattermost-gateway-https.yaml.tmpl" > "$YAML_DIR/mattermost-gateway.yaml"
    kubectl apply -f "$YAML_DIR/mattermost-gateway.yaml"
else
    echo "WARNING: TLS secret does not exist yet. Keeping Gateway with HTTP-only."
    echo "Run the script again after certificate is issued to add HTTPS."
fi

# Wait for Gateway to be Programmed with HTTPS
echo "Waiting for Gateway to be Programmed with HTTPS..."
for i in {1..30}; do
    STATUS=$(kubectl get gateway mattermost-gateway -n mattermost -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
    if [ "$STATUS" = "True" ]; then
        echo "Gateway is Programmed with HTTPS"
        break
    fi
    echo "Waiting for Gateway... ($i/30)"
    sleep 10
done

# Deploy Mattermost
echo ""
echo "Deploying Mattermost..."

# Check if Mattermost installation already exists
if kubectl get mm mattermost -n mattermost &>/dev/null; then
    echo "Mattermost installation already exists, checking pod status..."
    # Check if pods are ready
    if kubectl get pods -n mattermost -l app=mattermost -o name 2>/dev/null | grep -q pod; then
        if kubectl wait --for=condition=ready pod -l app=mattermost -n mattermost --timeout=10s &>/dev/null; then
            echo "Mattermost pods are already running and ready"
        else
            echo "Mattermost pods exist but are not ready, waiting..."
            kubectl wait --for=condition=ready pod -l app=mattermost -n mattermost --timeout=600s || true
        fi
    else
        echo "Mattermost resource exists but pods not yet created, waiting..."
        # Wait for pods to exist first
        RETRY_COUNT=0
        MAX_RETRIES=60
        until kubectl get pods -n mattermost -l app=mattermost -o name 2>/dev/null | grep -q pod; do
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
                echo "WARNING: Mattermost pods not created in time"
                break
            fi
            echo "Waiting for pods to be created (attempt $RETRY_COUNT/$MAX_RETRIES)..."
            sleep 5
        done

        if kubectl get pods -n mattermost -l app=mattermost -o name 2>/dev/null | grep -q pod; then
            echo "Waiting for Mattermost pods to be ready..."
            kubectl wait --for=condition=ready pod -l app=mattermost -n mattermost --timeout=600s || true
        fi
    fi
else
    echo "Creating Mattermost installation..."
    kubectl apply -f "$YAML_DIR/mattermost-installation-minio.yaml"

    echo ""
    echo "Waiting for Mattermost pods to be created..."
    # Wait for pods to exist first
    RETRY_COUNT=0
    MAX_RETRIES=60
    until kubectl get pods -n mattermost -l app=mattermost -o name 2>/dev/null | grep -q pod; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            echo "WARNING: Mattermost pods not created in time"
            break
        fi
        echo "Waiting for pods to be created (attempt $RETRY_COUNT/$MAX_RETRIES)..."
        sleep 5
    done

    if kubectl get pods -n mattermost -l app=mattermost -o name 2>/dev/null | grep -q pod; then
        echo "Waiting for Mattermost pods to be ready (this may take several minutes)..."
        kubectl wait --for=condition=ready pod -l app=mattermost -n mattermost --timeout=600s || true
    fi
fi

echo ""
echo "=============================================="
echo "  Deployment Complete!"
echo "=============================================="
echo ""
echo "Mattermost is available at: https://$DOMAIN"
echo "Gateway IP: $GATEWAY_IP"
echo ""
echo "Deployment Status:"
kubectl get gateway mattermost-gateway -n mattermost
echo ""
kubectl get certificate -n mattermost
echo ""
kubectl get mm -n mattermost
echo ""
echo "Useful Commands:"
echo "  kubectl logs -n mattermost deployment/mattermost        # View Mattermost logs"
echo "  kubectl get pods -n mattermost                          # Check pod status"
echo "  kubectl get pods -n mattermost-minio                    # Check MinIO pods"
