#!/bin/bash
set -e

echo "=========================================="
echo "Deploying Mattermost with NFS Storage"
echo "=========================================="

# Load environment variables from .env file
if [ ! -f .env ]; then
    echo "ERROR: .env file not found!"
    echo ""
    echo "Please create a .env file with your configuration:"
    echo "  Run: make env"
    echo "  Then edit .env and update DOMAIN and EMAIL"
    echo ""
    exit 1
fi

echo "Loading configuration from .env file..."
source .env

# Set defaults for optional variables
RESOURCE_GROUP="${RESOURCE_GROUP:-mattermost-test-rg}"
CLUSTER_NAME="${CLUSTER_NAME:-mattermost-test-aks}"
LOCATION="${LOCATION:-eastus}"
POSTGRES_SERVER="${POSTGRES_SERVER:-mattermost-postgres}"
DOMAIN="${DOMAIN:-mattermost.example.com}"
EMAIL="${EMAIL:-admin@example.com}"

# Validate required secrets
if [[ "$POSTGRES_PASSWORD" == *"CHANGE_ME"* ]]; then
    echo "ERROR: Placeholder password detected in .env file!"
    echo ""
    echo "Please generate secure secrets by running:"
    echo "  make env"
    echo ""
    exit 1
fi

echo "Using configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Cluster Name: $CLUSTER_NAME"
echo "  Location: $LOCATION"
echo "  Domain: $DOMAIN"
echo ""

# Step 1: Ensure AKS cluster exists
echo "Step 1: Checking AKS cluster..."
if ! az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" &>/dev/null; then
    echo "ERROR: AKS cluster does not exist. Run 'make deploy-minio' first to create the cluster."
    exit 1
fi

az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --admin --overwrite-existing

# Step 2: Ensure PostgreSQL exists
echo ""
echo "Step 2: Checking PostgreSQL database..."
if ! az postgres flexible-server show --resource-group "$RESOURCE_GROUP" --name "$POSTGRES_SERVER" &>/dev/null; then
    echo "ERROR: PostgreSQL server does not exist. Run 'make deploy-minio' first."
    exit 1
fi

POSTGRES_HOST=$(az postgres flexible-server show --resource-group "$RESOURCE_GROUP" --name "$POSTGRES_SERVER" --query "fullyQualifiedDomainName" -o tsv)
CONNECTION_STRING="postgres://mmuser:$POSTGRES_PASSWORD@$POSTGRES_HOST/mattermost?sslmode=require"
CONNECTION_STRING_BASE64=$(echo -n "$CONNECTION_STRING" | base64)

# Step 3: Create NFS storage resources
echo ""
echo "Step 3: Creating NFS storage resources..."
mkdir -p nfs-storage

# Create storage class
cat > nfs-storage/storage-class.yaml <<EOF
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

# Create PVC
cat > nfs-storage/mattermost-nfs-pvc.yaml <<EOF
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
kubectl apply -f nfs-storage/storage-class.yaml
kubectl create namespace mattermost --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f nfs-storage/mattermost-nfs-pvc.yaml

echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/mattermost-files -n mattermost --timeout=300s

# Step 4: Create Mattermost secrets
echo ""
echo "Step 4: Creating Mattermost secrets..."

# Create postgres secret
cat > mattermost-secret-postgres.yaml <<EOF
apiVersion: v1
data:
  DB_CONNECTION_CHECK_URL: $CONNECTION_STRING_BASE64
  DB_CONNECTION_STRING: $CONNECTION_STRING_BASE64
kind: Secret
metadata:
  name: mattermost-postgres
  namespace: mattermost
type: Opaque
EOF
kubectl apply -f mattermost-secret-postgres.yaml

# Step 5: Ensure Gateway API resources exist
echo ""
echo "Step 5: Checking Gateway API resources..."
if ! kubectl get gateway mattermost-gateway -n mattermost &>/dev/null; then
    echo "Gateway not found, creating..."

    # Gateway Class
    cat > gateway-class.yaml <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: azure-alb-external
spec:
  controllerName: alb.networking.azure.io/alb-controller
EOF
    kubectl apply -f gateway-class.yaml

    # Cluster Issuer
    cat > cluster-issuer.yaml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $EMAIL
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        gatewayHTTPRoute:
          parentRefs:
          - name: mattermost-gateway
            namespace: mattermost
            kind: Gateway
EOF
    kubectl apply -f cluster-issuer.yaml

    # Gateway
    cat > mattermost-gateway.yaml <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: mattermost-gateway
  namespace: mattermost
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  gatewayClassName: azure-alb-external
  listeners:
  - name: http-listener
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
  - name: https-listener
    protocol: HTTPS
    port: 443
    allowedRoutes:
      namespaces:
        from: Same
    tls:
      mode: Terminate
      certificateRefs:
      - name: mattermost-tls-cert
        kind: Secret
EOF
    kubectl apply -f mattermost-gateway.yaml

    # HTTPRoute
    cat > mattermost-httproute.yaml <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mattermost-route
  namespace: mattermost
spec:
  parentRefs:
  - name: mattermost-gateway
    namespace: mattermost
  hostnames:
  - "$DOMAIN"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: mattermost
      port: 8065
    timeouts:
      request: 600s
EOF
    kubectl apply -f mattermost-httproute.yaml
fi

# Step 6: Deploy Mattermost with NFS
echo ""
echo "Step 6: Deploying Mattermost with NFS storage..."

# Delete existing Mattermost if it exists
kubectl delete mattermost mattermost -n mattermost --ignore-not-found=true
echo "Waiting for existing Mattermost to be deleted..."
sleep 30

# Create installation manifest with NFS volume
cat > mattermost-installation-nfs.yaml <<EOF
apiVersion: installation.mattermost.com/v1beta1
kind: Mattermost
metadata:
  name: mattermost
  namespace: mattermost
spec:
  size: 100users
  database:
    external:
      secret: mattermost-postgres
  image: mattermost/mattermost-enterprise-edition
  imagePullPolicy: IfNotPresent
  mattermostEnv:
  - name: MM_FILESETTINGS_DRIVERNAME
    value: "local"
  - name: MM_FILESETTINGS_DIRECTORY
    value: "/mattermost/data"
  version: 11.2.1
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

kubectl apply -f mattermost-installation-nfs.yaml

echo ""
echo "Waiting for Mattermost to be ready (this may take several minutes)..."
kubectl -n mattermost wait --for=condition=ready mattermost/mattermost --timeout=600s || true

echo ""
echo "=========================================="
echo "NFS Deployment Complete!"
echo "=========================================="
echo ""
echo "Storage Type: NFS (Azure Files Premium)"
echo ""
echo "PVC Status:"
kubectl get pvc -n mattermost

echo ""
echo "Gateway Status:"
kubectl get gateway mattermost-gateway -n mattermost

echo ""
echo "Gateway IP:"
GATEWAY_IP=$(kubectl get gateway mattermost-gateway -n mattermost -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "Not ready yet")
echo "$GATEWAY_IP"

echo ""
echo "Mattermost Status:"
kubectl get mm -n mattermost

echo ""
echo "Next steps:"
echo "1. Update DNS: $DOMAIN -> $GATEWAY_IP"
echo "2. Access Mattermost at https://$DOMAIN"
echo ""
echo "To check Mattermost logs:"
echo "  kubectl logs -n mattermost deployment/mattermost"
echo ""
echo "To verify NFS volume is mounted:"
echo "  kubectl exec -n mattermost deployment/mattermost -- df -h /mattermost/data"
