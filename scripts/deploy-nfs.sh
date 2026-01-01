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
echo "Deploying Mattermost with NFS Storage"
echo "=========================================="

# Load and validate configuration
load_and_validate_config "$SCRIPT_DIR"

# Check if YAML directory exists and has required files
# If not, generate them (allows script to run standalone)
if [ ! -d "$YAML_DIR" ] || [ ! -f "$YAML_DIR/mattermost-installation-nfs.yaml" ]; then
    echo "YAML files not found. Generating from templates..."
    if [ -x "$SCRIPT_DIR/generate-yaml.sh" ]; then
        "$SCRIPT_DIR/generate-yaml.sh"
    else
        print_error "generate-yaml.sh not found or not executable"
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

# Create NFS storage resources
echo ""
echo "Creating NFS storage resources..."
mkdir -p "$REPO_ROOT/nfs-storage"

# Create storage class
cat > "$REPO_ROOT/nfs-storage/storage-class.yaml" <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-nfs-premium
provisioner: file.csi.azure.com
parameters:
  protocol: nfs
  skuName: Premium_LRS
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nconnect=4
  - nfsvers=4.1
  - hard
  - noatime
EOF

# Create namespace
kubectl create namespace mattermost --dry-run=client -o yaml | kubectl apply -f -

# Create PVC
cat > "$REPO_ROOT/nfs-storage/mattermost-nfs-pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mattermost-files
  namespace: mattermost
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-nfs-premium
  resources:
    requests:
      storage: 200Gi
EOF

echo "Applying NFS storage resources..."
kubectl apply -f "$REPO_ROOT/nfs-storage/storage-class.yaml"
kubectl apply -f "$REPO_ROOT/nfs-storage/mattermost-nfs-pvc.yaml"

echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/mattermost-files -n mattermost --timeout=300s || echo "PVC binding taking longer than expected"

print_success "NFS storage resources created"

# Install Mattermost Operator
install_mattermost_operator

# Create Mattermost secrets
echo ""
echo "Creating Mattermost secrets..."

# Apply secrets from pre-generated YAML
kubectl apply -f "$YAML_DIR/mattermost-secret-postgres.yaml"
if [ -f "$YAML_DIR/mattermost-secret-license.yaml" ]; then
    kubectl apply -f "$YAML_DIR/mattermost-secret-license.yaml"
fi

print_success "Secrets created"

# Create Gateway API resources (HTTP-only initially)
create_gateway_resources "$YAML_DIR"

# Configure DNS and wait for propagation
configure_dns_and_wait

# Provision TLS certificate
provision_tls_certificate "$YAML_DIR" "$TEMPLATES_DIR"

# Deploy Mattermost with NFS
echo ""
echo "Deploying Mattermost with NFS storage..."

# Create installation manifest with NFS volume
cat > "$YAML_DIR/mattermost-installation-nfs.yaml" <<EOF
apiVersion: installation.mattermost.com/v1beta1
kind: Mattermost
metadata:
  name: mattermost
  namespace: mattermost
spec:
  size: ${MATTERMOST_SIZE}
  ingress:
    enabled: true
    host: ${DOMAIN}
  database:
    external:
      secret: mattermost-postgres
  licenseSecret: mattermost-secret-license
  image: mattermost/mattermost-enterprise-edition
  imagePullPolicy: IfNotPresent
  mattermostEnv:
  - name: MM_FILESETTINGS_DRIVERNAME
    value: "local"
  - name: MM_FILESETTINGS_DIRECTORY
    value: "/mattermost/data"
  - name: MM_SERVICEENVIRONMENT
    value: "${MM_SERVICEENVIRONMENT}"
  version: ${MATTERMOST_VERSION}
  # Mount NFS volume
  podExtensions:
    extraVolumes:
    - name: mattermost-files
      persistentVolumeClaim:
        claimName: mattermost-files
    extraVolumeMounts:
    - name: mattermost-files
      mountPath: /mattermost/data
EOF

if kubectl get mattermost mattermost -n mattermost &>/dev/null; then
    echo "Mattermost already exists, updating..."
    kubectl apply -f "$YAML_DIR/mattermost-installation-nfs.yaml"
else
    kubectl apply -f "$YAML_DIR/mattermost-installation-nfs.yaml"
fi

echo ""
echo "Waiting for Mattermost to be ready (this may take several minutes)..."
kubectl -n mattermost wait --for=condition=ready mattermost/mattermost --timeout=600s || echo "Mattermost deployment taking longer than expected, check status manually"

# Final status
echo ""
echo "=========================================="
echo "  NFS Deployment Complete!"
echo "=========================================="
echo ""
echo "Mattermost URL: https://$DOMAIN"
echo "Storage Type: NFS (Azure Files Premium)"
echo ""
echo "PVC Status:"
kubectl get pvc -n mattermost
echo ""
echo "To check deployment status:"
echo "  make status"
echo ""
echo "To verify NFS volume is mounted:"
echo "  kubectl exec -n mattermost deployment/mattermost -- df -h /mattermost/data"
echo ""
echo "To view logs:"
echo "  make logs-mattermost"
echo ""
