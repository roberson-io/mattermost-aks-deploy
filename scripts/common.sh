#!/bin/bash
# Common functions for Mattermost AKS deployment scripts
# This library is sourced by deploy-minio.sh, deploy-nfs.sh, and deploy-s3proxy.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Print functions
print_error() {
    echo -e "${RED}ERROR: $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

# Load and validate configuration from .env file
load_and_validate_config() {
    local script_dir="$1"
    local repo_root="$(cd "$script_dir/.." && pwd)"

    if [ ! -f "$repo_root/.env" ]; then
        print_error ".env file not found!"
        echo ""
        echo "Please create a .env file with your configuration:"
        echo "  Run: make env"
        echo "  Then edit .env and update DOMAIN and EMAIL"
        echo ""
        exit 1
    fi

    echo "Loading configuration from .env file..."
    source "$repo_root/.env"

    # Validate required secrets
    if [[ "$POSTGRES_PASSWORD" == *"CHANGE_ME"* ]] || \
       [[ "$MINIO_ADMIN_PASSWORD" == *"CHANGE_ME"* ]] || \
       [[ "$MINIO_SERVICE_PASSWORD" == *"CHANGE_ME"* ]]; then
        print_error "Placeholder password detected in .env file!"
        echo ""
        echo "Please generate secure secrets by running:"
        echo "  make env"
        echo ""
        exit 1
    fi

    # Validate license file
    if [ -z "$LICENSE_FILE" ] || [ ! -f "$LICENSE_FILE" ]; then
        print_error "Mattermost license file not found: $LICENSE_FILE"
        echo ""
        echo "Please ensure LICENSE_FILE in .env points to a valid license file."
        echo ""
        exit 1
    fi

    echo "Using configuration:"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  Location: $LOCATION"
    echo "  Domain: $DOMAIN"
    echo ""
}

# Create AKS cluster with Azure CNI
create_aks_cluster() {
    echo ""
    echo "Creating AKS cluster..."
    echo "  Name: $CLUSTER_NAME"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Location: $LOCATION"
    echo "  Node Count: ${NODE_COUNT:-2}"
    echo "  Node VM Size: ${NODE_VM_SIZE:-Standard_D4s_v4}"
    echo ""

    if az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" &>/dev/null; then
        print_warning "AKS cluster already exists, skipping creation"
    else
        az aks create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$CLUSTER_NAME" \
            --enable-managed-identity \
            --node-count "${NODE_COUNT:-2}" \
            --node-vm-size "${NODE_VM_SIZE:-Standard_D4s_v4}" \
            --generate-ssh-keys \
            --network-plugin azure \
            --network-policy calico \
            --enable-blob-driver \
            --enable-workload-identity \
            --enable-oidc-issuer \
            --location "$LOCATION"

        echo "Waiting for AKS cluster to be ready (this may take 5-10 minutes)..."
        az aks wait --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --created --interval 30 --timeout 900
        print_success "AKS cluster created successfully"
    fi

    echo "Getting AKS credentials..."
    az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --admin --overwrite-existing
}

# Create PostgreSQL Flexible Server
create_postgresql() {
    echo ""
    echo "Creating PostgreSQL Flexible Server..."
    echo "  Server: $POSTGRES_SERVER"
    echo "  Version: ${POSTGRES_VERSION:-18}"
    echo ""

    if az postgres flexible-server show --resource-group "$RESOURCE_GROUP" --name "$POSTGRES_SERVER" &>/dev/null; then
        print_warning "PostgreSQL server already exists, skipping creation"
    else
        az postgres flexible-server create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$POSTGRES_SERVER" \
            --location "$LOCATION" \
            --admin-user "${POSTGRES_ADMIN_USER:-mmuser}" \
            --admin-password "$POSTGRES_PASSWORD" \
            --sku-name "${POSTGRES_SKU:-Standard_E2ds_v4}" \
            --tier "${POSTGRES_TIER:-MemoryOptimized}" \
            --storage-size "${POSTGRES_STORAGE_SIZE:-128}" \
            --version "${POSTGRES_VERSION:-18}" \
            --public-access "${POSTGRES_PUBLIC_ACCESS:-0.0.0.0}" \
            --yes

        print_success "PostgreSQL server created"

        echo "Creating $POSTGRES_DB database..."
        az postgres flexible-server db create \
            --resource-group "$RESOURCE_GROUP" \
            --server-name "$POSTGRES_SERVER" \
            --database-name "$POSTGRES_DB"

        print_success "Database created"
    fi
}

# Install cert-manager with Gateway API support
install_cert_manager() {
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
        print_warning "cert-manager already installed, skipping"
    fi
}

# Install ALB Controller
install_alb_controller() {
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
        print_warning "ALB Controller already installed, skipping"
    fi
}

# Create Application Gateway for Containers (ALB) infrastructure
create_alb_infrastructure() {
    echo ""
    echo "Creating Application Gateway for Containers infrastructure..."

    # Set ALB resource names
    local ALB_NAME="${CLUSTER_NAME}-alb"
    local ALB_FRONTEND_NAME="frontend-mattermost"
    local ALB_ASSOCIATION_NAME="association-mattermost"

    # Check if ALB already exists
    if az network alb show --resource-group "$RESOURCE_GROUP" --name "$ALB_NAME" &>/dev/null; then
        print_warning "Application Gateway for Containers already exists, skipping creation"
    else
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
        local NODE_RESOURCE_GROUP=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --query nodeResourceGroup -o tsv)
        local VNET_NAME=$(az network vnet list --resource-group "$NODE_RESOURCE_GROUP" --query "[0].name" -o tsv)
        local SUBNET_ID=$(az network vnet subnet list \
            --resource-group "$NODE_RESOURCE_GROUP" \
            --vnet-name "$VNET_NAME" \
            --query "[0].id" -o tsv)
        local SUBNET_NAME=$(az network vnet subnet list \
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

        echo "Creating ALB association with subnet..."
        az network alb association create \
            --resource-group "$RESOURCE_GROUP" \
            --alb-name "$ALB_NAME" \
            --name "$ALB_ASSOCIATION_NAME" \
            --subnet "$SUBNET_ID"

        print_success "Application Gateway for Containers created"
    fi

    # Get ALB ID and wait for provisioning
    export ALB_ID=$(az network alb show --resource-group "$RESOURCE_GROUP" --name "$ALB_NAME" --query id -o tsv)
    echo "ALB Resource ID: $ALB_ID"

    echo "Waiting for Application Gateway for Containers to be ready..."
    local RETRY_COUNT=0
    local MAX_RETRIES=30
    until az network alb show --resource-group "$RESOURCE_GROUP" --name "$ALB_NAME" --query "provisioningState" -o tsv 2>/dev/null | grep -q "Succeeded"; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            print_warning "ALB provisioning taking longer than expected, continuing anyway..."
            break
        fi
        echo "Waiting for ALB provisioning (attempt $RETRY_COUNT/$MAX_RETRIES)..."
        sleep 10
    done
    print_success "Application Gateway for Containers is ready"
}

# Install Mattermost Operator
install_mattermost_operator() {
    echo ""
    echo "Installing Mattermost Operator..."

    if kubectl get namespace mattermost-operator &>/dev/null; then
        print_warning "Mattermost Operator already installed, skipping"
    else
        helm repo add mattermost https://helm.mattermost.com
        helm repo update

        kubectl create ns mattermost-operator

        helm install mattermost-operator mattermost/mattermost-operator -n mattermost-operator

        echo "Waiting for Mattermost Operator to be ready..."
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mattermost-operator -n mattermost-operator --timeout=300s
        print_success "Mattermost Operator installed"
    fi
}

# Create Gateway API resources
create_gateway_resources() {
    local yaml_dir="$1"
    local templates_dir="$2"

    echo ""
    echo "Deploying Gateway API resources..."

    # Apply Gateway class and cluster issuer (idempotent with kubectl apply)
    kubectl apply -f "$yaml_dir/gateway-class.yaml"
    kubectl apply -f "$yaml_dir/cluster-issuer.yaml"

    # Check if Gateway exists
    if kubectl get gateway mattermost-gateway -n mattermost &>/dev/null; then
        echo "Gateway already exists, checking status..."
    else
        echo "Creating Gateway (HTTP only initially)..."
        # Generate and apply gateway from HTTP template
        export ALB_ID
        envsubst < "$templates_dir/mattermost-gateway-http.yaml.tmpl" > "$yaml_dir/mattermost-gateway.yaml"
        kubectl apply -f "$yaml_dir/mattermost-gateway.yaml"
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
    kubectl apply -f "$yaml_dir/mattermost-gateway-svc.yaml"
    export DOMAIN
    envsubst < "$templates_dir/mattermost-httproute.yaml.tmpl" > "$yaml_dir/mattermost-httproute.yaml"
    kubectl apply -f "$yaml_dir/mattermost-httproute.yaml"
}

# Configure DNS and wait for propagation
configure_dns_and_wait() {
    echo ""
    echo "Waiting for Gateway to get external IP..."
    GATEWAY_FQDN=""
    for i in {1..30}; do
        GATEWAY_FQDN=$(kubectl get gateway mattermost-gateway -n mattermost -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
        if [ -n "$GATEWAY_FQDN" ]; then
            break
        fi
        echo "Waiting for Gateway IP... ($i/30)"
        sleep 10
    done

    if [ -z "$GATEWAY_FQDN" ]; then
        print_error "Gateway did not get an external IP within 5 minutes"
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
        print_warning "'dig' command not found. Please install dnsutils (apt) or bind-tools (yum)"
        echo "Continuing without DNS verification..."
        read -p "Press ENTER after you have updated DNS (or Ctrl+C to cancel)..."
    else
        # DNS Verification Loop
        echo "Checking DNS propagation (using DNS server: ${DNS_SERVER:-8.8.8.8})..."
        DNS_READY=false
        for i in {1..30}; do
            RESOLVED_IP=$(dig +short "$DOMAIN" @${DNS_SERVER:-8.8.8.8} | grep -E '^[0-9.]+$' | head -1)

            if [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" = "$GATEWAY_IP" ]; then
                print_success "DNS propagated successfully! $DOMAIN resolves to $GATEWAY_IP"
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

        if [ "$DNS_READY" = "false" ]; then
            print_warning "DNS propagation timeout after 5 minutes"
            echo "Please verify your DNS configuration and wait for propagation"
            read -p "Press ENTER to continue anyway (or Ctrl+C to cancel)..."
        fi
    fi
}

# Provision TLS certificate with ACME challenge
provision_tls_certificate() {
    local yaml_dir="$1"
    local templates_dir="$2"

    echo ""
    echo "Creating TLS certificate for Gateway..."

    # Check if certificate exists
    CERT_EXISTS=false
    if kubectl get certificate mattermost-tls-cert -n mattermost &>/dev/null; then
        CERT_EXISTS=true
        CERT_READY=$(kubectl get certificate mattermost-tls-cert -n mattermost -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [ "$CERT_READY" = "True" ]; then
            print_success "Certificate already exists and is ready"
        else
            echo "Certificate exists but is not ready, checking ACME challenge setup..."
        fi
    else
        echo "Creating certificate resource..."
        export DOMAIN
        export EMAIL
        envsubst < "$templates_dir/mattermost-certificate.yaml.tmpl" | kubectl apply -f -
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
                print_success "Found ACME solver service: $SOLVER_SVC"
                break
            fi
            echo "Waiting for solver service... ($i/30)"
            sleep 5
        done

        if [ -n "$SOLVER_SVC" ]; then
            # Create HTTPRoute for ACME challenge
            echo "Creating HTTPRoute for ACME challenge..."
            export SOLVER_SVC
            envsubst < "$templates_dir/mattermost-acme-challenge.yaml.tmpl" > "$yaml_dir/mattermost-acme-challenge.yaml"
            kubectl apply -f "$yaml_dir/mattermost-acme-challenge.yaml"
            print_success "ACME challenge HTTPRoute created"
        else
            print_warning "ACME solver service not found. Certificate may fail to issue."
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
        print_success "TLS secret exists, adding HTTPS listener to Gateway..."
        export DOMAIN
        envsubst < "$templates_dir/mattermost-gateway-https.yaml.tmpl" > "$yaml_dir/mattermost-gateway.yaml"
        kubectl apply -f "$yaml_dir/mattermost-gateway.yaml"
    else
        print_warning "TLS secret does not exist yet. Keeping Gateway with HTTP-only."
        echo "Run the script again after certificate is issued to add HTTPS."
    fi

    # Wait for Gateway to be Programmed with HTTPS
    echo "Waiting for Gateway to be Programmed with HTTPS..."
    for i in {1..30}; do
        STATUS=$(kubectl get gateway mattermost-gateway -n mattermost -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
        if [ "$STATUS" = "True" ]; then
            print_success "Gateway updated with HTTPS"
            break
        fi
        echo "Waiting for Gateway... ($i/30)"
        sleep 10
    done
}
