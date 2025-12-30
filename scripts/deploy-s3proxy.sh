#!/bin/bash
set -e

echo "=========================================="
echo "Deploying Mattermost with s3proxy + Azure Blob Storage"
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
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-mmstorageblob$(date +%s)}"
DOMAIN="${DOMAIN:-mattermost.example.com}"
EMAIL="${EMAIL:-admin@example.com}"

# Validate required secrets
if [[ "$POSTGRES_PASSWORD" == *"CHANGE_ME"* ]] || \
   [[ "$S3PROXY_PASSWORD" == *"CHANGE_ME"* ]]; then
    echo "ERROR: Placeholder passwords detected in .env file!"
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
echo "  Storage Account: $STORAGE_ACCOUNT"
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

# Step 3: Create Azure Storage Account
echo ""
echo "Step 3: Creating Azure Storage Account..."
if ! az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" &>/dev/null; then
    echo "Creating storage account $STORAGE_ACCOUNT..."
    az storage account create \
        --name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --sku Standard_LRS \
        --kind StorageV2 \
        --allow-blob-public-access false

    echo "Waiting for storage account to be ready..."
    sleep 10
else
    echo "Storage account already exists, skipping creation"
fi

# Get storage account key
STORAGE_KEY=$(az storage account keys list --resource-group "$RESOURCE_GROUP" --account-name "$STORAGE_ACCOUNT" --query '[0].value' -o tsv)

# Create container
echo "Creating mattermost container..."
az storage container create \
    --name mattermost \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --auth-mode key || echo "Container already exists"

# Step 4: Deploy s3proxy
echo ""
echo "Step 4: Deploying s3proxy..."
mkdir -p s3proxy

# Create namespace
cat > s3proxy/namespace.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: s3proxy
EOF

# Create Azure storage secret
cat > s3proxy/azure-storage-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: azure-storage-credentials
  namespace: s3proxy
type: Opaque
stringData:
  JCLOUDS_IDENTITY: "$STORAGE_ACCOUNT"
  JCLOUDS_CREDENTIAL: "$STORAGE_KEY"
  JCLOUDS_ENDPOINT: "https://$STORAGE_ACCOUNT.blob.core.windows.net"
EOF

# Create s3proxy config
cat > s3proxy/s3proxy-config.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: s3proxy-config
  namespace: s3proxy
data:
  s3proxy.conf: |
    s3proxy.authorization=none
    s3proxy.endpoint=http://0.0.0.0:8080
    jclouds.provider=azureblob
    jclouds.identity=\${JCLOUDS_IDENTITY}
    jclouds.credential=\${JCLOUDS_CREDENTIAL}
    jclouds.endpoint=\${JCLOUDS_ENDPOINT}
EOF

# Create deployment
cat > s3proxy/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: s3proxy
  namespace: s3proxy
  labels:
    app: s3proxy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: s3proxy
  template:
    metadata:
      labels:
        app: s3proxy
    spec:
      containers:
      - name: s3proxy
        image: andrewgaul/s3proxy:latest
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP
        env:
        - name: JCLOUDS_IDENTITY
          valueFrom:
            secretKeyRef:
              name: azure-storage-credentials
              key: JCLOUDS_IDENTITY
        - name: JCLOUDS_CREDENTIAL
          valueFrom:
            secretKeyRef:
              name: azure-storage-credentials
              key: JCLOUDS_CREDENTIAL
        - name: JCLOUDS_ENDPOINT
          valueFrom:
            secretKeyRef:
              name: azure-storage-credentials
              key: JCLOUDS_ENDPOINT
        - name: S3PROXY_AUTHORIZATION
          value: "aws-v2-or-v4"
        - name: S3PROXY_IDENTITY
          value: "mattermost"
        - name: S3PROXY_CREDENTIAL
          value: "$S3PROXY_PASSWORD"
        volumeMounts:
        - name: config
          mountPath: /opt/s3proxy/s3proxy.conf
          subPath: s3proxy.conf
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: 2000m
            memory: 2Gi
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: config
        configMap:
          name: s3proxy-config
EOF

# Create service
cat > s3proxy/service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: s3proxy
  namespace: s3proxy
spec:
  selector:
    app: s3proxy
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
  type: ClusterIP
EOF

# Create kustomization
cat > s3proxy/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: s3proxy
resources:
- namespace.yaml
- azure-storage-secret.yaml
- s3proxy-config.yaml
- deployment.yaml
- service.yaml
EOF

echo "Applying s3proxy resources..."
kubectl apply -k ./s3proxy/

echo "Waiting for s3proxy pods to be ready..."
kubectl wait --for=condition=ready pod -l app=s3proxy -n s3proxy --timeout=300s

# Step 5: Create Mattermost secrets
echo ""
echo "Step 5: Creating Mattermost secrets..."
kubectl create namespace mattermost --dry-run=client -o yaml | kubectl apply -f -

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

# Create s3proxy secret
S3PROXY_ACCESS_KEY_BASE64=$(echo -n "mattermost" | base64)
S3PROXY_SECRET_KEY_BASE64=$(echo -n "$S3PROXY_PASSWORD" | base64)

cat > mattermost-secret-s3proxy.yaml <<EOF
apiVersion: v1
data:
  accesskey: $S3PROXY_ACCESS_KEY_BASE64
  secretkey: $S3PROXY_SECRET_KEY_BASE64
kind: Secret
metadata:
  name: mattermost-secret-s3proxy
  namespace: mattermost
type: Opaque
EOF
kubectl apply -f mattermost-secret-s3proxy.yaml

# Step 6: Ensure Gateway API resources exist
echo ""
echo "Step 6: Checking Gateway API resources..."
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

# Step 7: Deploy Mattermost with s3proxy
echo ""
echo "Step 7: Deploying Mattermost with s3proxy storage..."

# Delete existing Mattermost if it exists
kubectl delete mattermost mattermost -n mattermost --ignore-not-found=true
echo "Waiting for existing Mattermost to be deleted..."
sleep 30

# Create installation manifest
cat > mattermost-installation-s3proxy.yaml <<EOF
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
  fileStore:
    external:
      url: s3proxy.s3proxy.svc.cluster.local
      bucket: mattermost
      secret: mattermost-secret-s3proxy
  image: mattermost/mattermost-enterprise-edition
  imagePullPolicy: IfNotPresent
  mattermostEnv:
  - name: MM_FILESETTINGS_AMAZONS3SSE
    value: "false"
  - name: MM_FILESETTINGS_AMAZONS3SSL
    value: "false"
  - name: MM_FILESETTINGS_AMAZONS3PATHSTYLE
    value: "true"
  version: 11.2.1
EOF

kubectl apply -f mattermost-installation-s3proxy.yaml

echo ""
echo "Waiting for Mattermost to be ready (this may take several minutes)..."
kubectl -n mattermost wait --for=condition=ready mattermost/mattermost --timeout=600s || true

echo ""
echo "=========================================="
echo "s3proxy Deployment Complete!"
echo "=========================================="
echo ""
echo "Storage Type: s3proxy + Azure Blob Storage"
echo "Storage Account: $STORAGE_ACCOUNT"
echo ""
echo "s3proxy Status:"
kubectl get pods -n s3proxy

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
echo "To check s3proxy logs:"
echo "  kubectl logs -n s3proxy deployment/s3proxy"
echo ""
echo "To check Mattermost logs:"
echo "  kubectl logs -n mattermost deployment/mattermost"
echo ""
echo "To verify Azure Blob storage:"
echo "  az storage blob list --account-name $STORAGE_ACCOUNT --container-name mattermost --account-key <key>"
