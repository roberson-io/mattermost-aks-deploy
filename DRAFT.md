# Mattermost on Azure Kubernetes Service (AKS)

This guide shows you how to deploy Mattermost on Azure Kubernetes Service with Gateway API for ingress and MinIO for file storage.

This guide **does not** show you how to properly lock down your Azure tenant or configure production-grade security settings.

## Prerequisites

### Required Tools

- **Azure Account** with sufficient quota for AKS cluster
- **Domain Name** that you can configure DNS for
- **kubectl** - Kubernetes command-line tool
- **Azure CLI** - For managing Azure resources
- **helm** - Kubernetes package manager
- **mc** - MinIO client for bucket configuration

### Installing Tools

**macOS:**

```bash
# Install Azure CLI
brew update && brew install azure-cli

# Install kubectl
brew install kubectl

# Install helm
brew install helm

# Install MinIO client
brew install minio/stable/mc
```

**Linux/Windows:**
- Azure CLI: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
- kubectl: https://kubernetes.io/docs/tasks/tools/
- helm: https://helm.sh/docs/intro/install/
- mc: https://min.io/docs/minio/linux/reference/minio-mc.html

## Deployment Steps

### 1. Azure CLI Authentication

Authenticate the Azure CLI (this will open a browser window):

```bash
az login
```

If you need a specific tenant:

```bash
az login --tenant yourTenant.com
```

### 2. Create Resource Group

Choose a resource group name and location:

```bash
export RESOURCE_GROUP="mattermost-rg"
export LOCATION="eastus2"

az group create --name $RESOURCE_GROUP --location $LOCATION
```

### 3. Create AKS Cluster

Create an AKS cluster with Azure CNI networking:

```bash
export CLUSTER_NAME="mattermost-aks"

az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --location $LOCATION \
  --enable-managed-identity \
  --node-count 3 \
  --node-vm-size Standard_D4s_v4 \
  --generate-ssh-keys \
  --network-plugin azure \
  --network-policy calico \
  --enable-blob-driver \
  --enable-workload-identity \
  --enable-oidc-issuer
```

**Important:** Use `--network-plugin azure` (not kubenet). Azure Application Gateway for Containers requires Azure CNI.

Get cluster credentials:

```bash
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --admin
```

Verify cluster access:

```bash
kubectl get nodes
```

### 4. Create PostgreSQL Database

Create a PostgreSQL Flexible Server:

```bash
export POSTGRES_SERVER="mattermost-postgres"
export POSTGRES_ADMIN_USER="mmadmin"
export POSTGRES_ADMIN_PASSWORD="$(openssl rand -base64 32)"

echo "PostgreSQL Admin Password: $POSTGRES_ADMIN_PASSWORD"  # Save this!

az postgres flexible-server create \
  --name $POSTGRES_SERVER \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --admin-user $POSTGRES_ADMIN_USER \
  --admin-password "$POSTGRES_ADMIN_PASSWORD" \
  --sku-name Standard_E2ds_v4 \
  --tier MemoryOptimized \
  --storage-size 128 \
  --version 18 \
  --public-access 0.0.0.0
```

Create the Mattermost database:

```bash
az postgres flexible-server db create \
  --resource-group $RESOURCE_GROUP \
  --server-name $POSTGRES_SERVER \
  --database-name mattermost
```

Create Kubernetes namespace and secret:

```bash
kubectl create namespace mattermost
```

Edit [mattermost-postgres-secret.yaml](mattermost-postgres-secret.yaml) and replace the placeholders with your PostgreSQL credentials, then apply:

```bash
kubectl apply -f mattermost-postgres-secret.yaml
```

Verify the secret was created:

```bash
kubectl get secret mattermost-postgres -n mattermost
```

### 5. Install cert-manager

Install cert-manager for TLS certificate management:

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.19.2 \
  --set crds.enabled=true
```

Wait for cert-manager:

```bash
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager --timeout=300s
```

### 6. Install Azure Application Gateway for Containers

Azure Application Gateway for Containers is a load balancer that implements the Kubernetes Gateway API. It provides ingress to the cluster and handles TLS termination for HTTPS traffic.

Create managed identity:

```bash
az identity create \
  --resource-group $RESOURCE_GROUP \
  --name alb-controller-identity \
  --location $LOCATION

IDENTITY_PRINCIPAL_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name alb-controller-identity \
  --query principalId -o tsv)

IDENTITY_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name alb-controller-identity \
  --query clientId -o tsv)
```

Assign permissions:

```bash
az role assignment create \
  --assignee-object-id $IDENTITY_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --scope "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP" \
  --role "AppGw for Containers Configuration Manager"
```

Create federated identity credential:

```bash
AKS_OIDC_ISSUER=$(az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --query oidcIssuerProfile.issuerUrl -o tsv)

az identity federated-credential create \
  --name alb-controller-federated-credential \
  --identity-name alb-controller-identity \
  --resource-group $RESOURCE_GROUP \
  --issuer "$AKS_OIDC_ISSUER" \
  --subject system:serviceaccount:azure-alb-system:alb-controller-sa \
  --audience api://AzureADTokenExchange
```

Install ALB Controller:

```bash
helm install alb-controller \
  oci://mcr.microsoft.com/application-lb/charts/alb-controller \
  --namespace azure-alb-system \
  --create-namespace \
  --set albController.namespace=azure-alb-system \
  --set albController.podIdentity.clientID="$IDENTITY_CLIENT_ID"
```

Wait for ALB Controller:

```bash
kubectl wait --for=condition=ready pod \
  -l app=alb-controller \
  -n azure-alb-system --timeout=300s
```

### 7. Create Application Gateway for Containers

```bash
ALB_NAME="${CLUSTER_NAME}-alb"

az network alb create \
  --resource-group $RESOURCE_GROUP \
  --name $ALB_NAME \
  --location $LOCATION

az network alb frontend create \
  --resource-group $RESOURCE_GROUP \
  --alb-name $ALB_NAME \
  --name frontend-mattermost
```

Create association with AKS subnet:

```bash
NODE_RESOURCE_GROUP=$(az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --query nodeResourceGroup -o tsv)

VNET_NAME=$(az network vnet list \
  --resource-group $NODE_RESOURCE_GROUP \
  --query "[0].name" -o tsv)

SUBNET_ID=$(az network vnet subnet list \
  --resource-group $NODE_RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --query "[0].id" -o tsv)

SUBNET_NAME=$(az network vnet subnet list \
  --resource-group $NODE_RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --query "[0].name" -o tsv)

# Delegate the subnet to Traffic Controller
az network vnet subnet update \
  --resource-group $NODE_RESOURCE_GROUP \
  --vnet-name $VNET_NAME \
  --name $SUBNET_NAME \
  --delegations Microsoft.ServiceNetworking/trafficControllers

az network alb association create \
  --resource-group $RESOURCE_GROUP \
  --alb-name $ALB_NAME \
  --name association-mattermost \
  --subnet $SUBNET_ID
```

Get the ALB ID:

```bash
ALB_ID=$(az network alb show \
  --resource-group $RESOURCE_GROUP \
  --name $ALB_NAME \
  --query id -o tsv)

echo "ALB_ID: $ALB_ID"
```

### 8. Create Gateway API Resources

Create GatewayClass:

```bash
kubectl apply -f gateway-class.yaml
```

Edit [cluster-issuer.yaml](cluster-issuer.yaml) and replace `YOUR_EMAIL` with your email address, then apply:

```bash
kubectl apply -f cluster-issuer.yaml
```

Edit [mattermost-gateway.yaml](mattermost-gateway.yaml) and replace `YOUR_ALB_ID` with your ALB ID (from step 7), then apply:

```bash
kubectl apply -f mattermost-gateway.yaml
```

**Note:** The Gateway will initially only have an HTTP listener. We'll add HTTPS after the TLS certificate is issued.

Wait for Gateway to get an external IP:

```bash
kubectl wait --for=condition=Programmed gateway mattermost-gateway -n mattermost --timeout=300s

GATEWAY_FQDN=$(kubectl get gateway mattermost-gateway -n mattermost -o jsonpath='{.status.addresses[0].value}')
GATEWAY_IP=$(dig +short "$GATEWAY_FQDN" | head -1)

echo "Gateway IP: $GATEWAY_IP"
```

**IMPORTANT:** Update your DNS to point your domain to the Gateway IP before continuing.

### 9. Install MinIO Operator

```bash
kubectl apply -k "https://github.com/minio/operator?ref=v7.1.1"
```

Wait for operator:

```bash
kubectl wait --for=condition=ready pod \
  -l name=minio-operator \
  -n minio-operator --timeout=300s
```

### 10. Create MinIO Tenant

Generate MinIO credentials:

```bash
export MINIO_ADMIN_USER="admin"
export MINIO_ADMIN_PASSWORD="$(openssl rand -base64 32)"
export MINIO_SERVICE_USER="mattermost"
export MINIO_SERVICE_PASSWORD="$(openssl rand -base64 32)"

echo "MinIO Admin: $MINIO_ADMIN_USER / $MINIO_ADMIN_PASSWORD"
echo "MinIO Service: $MINIO_SERVICE_USER / $MINIO_SERVICE_PASSWORD"
```

Edit [minio-tenant-kustomize/tenant-credentials-secret.yaml](minio-tenant-kustomize/tenant-credentials-secret.yaml) and replace `YOUR_MINIO_ADMIN_USER` and `YOUR_MINIO_ADMIN_PASSWORD` with the admin credentials from above.

Edit [minio-tenant-kustomize/mattermost-user-secret.yaml](minio-tenant-kustomize/mattermost-user-secret.yaml) and replace `YOUR_MINIO_SERVICE_USER` and `YOUR_MINIO_SERVICE_PASSWORD` with the service credentials from above.

Deploy MinIO tenant and all resources:

```bash
kubectl apply -k minio-tenant-kustomize/
```

Wait for MinIO tenant:

```bash
kubectl wait --for=jsonpath='{.status.currentState}'=Initialized \
  tenant/minio-mattermost \
  -n mattermost-minio --timeout=600s
```

### 11. Configure MinIO Bucket

Port-forward to MinIO:

```bash
kubectl port-forward svc/minio -n mattermost-minio 9000:80
```

Configure mc client:

```bash
mc alias set minio-local http://localhost:9000 $MINIO_ADMIN_USER $MINIO_ADMIN_PASSWORD
```

Create bucket and user:

```bash
# Create bucket
mc mb minio-local/mattermost

# Create service user
mc admin user add minio-local $MINIO_SERVICE_USER $MINIO_SERVICE_PASSWORD

# Create and apply policy (using existing minio-policy.json file)
mc admin policy create minio-local mattermost-policy minio-policy.json
mc admin policy attach minio-local mattermost-policy --user=$MINIO_SERVICE_USER
```

Stop port-forward:

```bash
pkill -f "kubectl port-forward svc/minio"
```

Create the Mattermost MinIO secret:

Edit [mattermost-secret-minio.yaml](mattermost-secret-minio.yaml) and replace `YOUR_MINIO_SERVICE_USER` and `YOUR_MINIO_SERVICE_PASSWORD` with the service credentials from above.

Apply the secret:

```bash
kubectl apply -f mattermost-secret-minio.yaml
```

### 12. Create TLS Certificate

Edit [mattermost-certificate.yaml](mattermost-certificate.yaml) and replace `YOUR_DOMAIN` with your domain.

Apply the certificate:

```bash
kubectl apply -f mattermost-certificate.yaml
```

Wait for the ACME solver service:

```bash
kubectl get svc -n mattermost -l acme.cert-manager.io/http01-solver=true -w
```

Once the solver service appears (press Ctrl+C to stop watching), get the solver service name:

```bash
kubectl get svc -n mattermost -l acme.cert-manager.io/http01-solver=true -o jsonpath='{.items[0].metadata.name}'
```

Edit [mattermost-acme-httproute.yaml](mattermost-acme-httproute.yaml) and replace `YOUR_DOMAIN` with your domain and `YOUR_SOLVER_SERVICE` with the solver service name from above.

Apply the HTTPRoute:

```bash
kubectl apply -f mattermost-acme-httproute.yaml
```

Wait for certificate:

```bash
kubectl wait --for=condition=ready certificate mattermost-tls-cert -n mattermost --timeout=300s
```

Clean up ACME HTTPRoute:

```bash
kubectl delete httproute acme-challenge -n mattermost
```

### 13. Add HTTPS to Gateway

Edit [mattermost-gateway.yaml](mattermost-gateway.yaml) and add the HTTPS listener to the `listeners` array:

```yaml
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
```

Apply the updated Gateway:

```bash
kubectl apply -f mattermost-gateway.yaml
```

### 14. Install Mattermost Operator

Add the Mattermost Helm repository:

```bash
helm repo add mattermost https://helm.mattermost.com
```

Create namespace:

```bash
kubectl create ns mattermost-operator
```

Install the operator:

```bash
helm install mattermost-operator mattermost/mattermost-operator -n mattermost-operator
```

Wait for operator:

```bash
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=mattermost-operator \
  -n mattermost-operator --timeout=300s
```

### 15. Deploy Mattermost

Create a ClusterIP service for Gateway routing:

```bash
kubectl apply -f mattermost-gateway-svc.yaml
```

Create the license secret:

First, base64 encode your license file:

```bash
cat your-license.mattermost | base64
```

Edit [mattermost-secret-license.yaml](mattermost-secret-license.yaml) and replace `YOUR_BASE64_ENCODED_LICENSE` with the base64 output from above.

Apply the secret:

```bash
kubectl apply -f mattermost-secret-license.yaml
```

Edit [mattermost-httproute.yaml](mattermost-httproute.yaml) and replace `YOUR_DOMAIN` with your domain, then apply:

```bash
kubectl apply -f mattermost-httproute.yaml
```

Edit [mattermost-installation-minio.yaml](mattermost-installation-minio.yaml) and replace `YOUR_DOMAIN` with your domain, then apply:

```bash
kubectl apply -f mattermost-installation-minio.yaml
```

Wait for Mattermost:

```bash
kubectl wait --for=condition=ready pod \
  -l app=mattermost \
  -n mattermost --timeout=600s
```

### 16. Verify Deployment

Check Mattermost status:

```bash
kubectl get mattermost -n mattermost
```

Test HTTPS access:

```bash
curl -s https://$DOMAIN/api/v4/system/ping
```

You should see: `{"status":"OK",...}`

## Accessing Mattermost

Navigate to `https://your-domain.com` in your browser to access Mattermost and complete the initial setup.

## Common Operations

### View Logs

```bash
kubectl logs -n mattermost -l app=mattermost -f
```

### Restart Mattermost

```bash
kubectl rollout restart deployment -n mattermost -l app=mattermost
```

### Check Gateway Status

```bash
kubectl get gateway mattermost-gateway -n mattermost
kubectl describe gateway mattermost-gateway -n mattermost
```

### Check Certificate Status

```bash
kubectl get certificate -n mattermost
kubectl describe certificate mattermost-tls-cert -n mattermost
```

## Troubleshooting

### Gateway Not Getting IP

Check ALB Controller logs:

```bash
kubectl logs -n azure-alb-system -l app=alb-controller
```

### Certificate Not Issuing

Check challenges:

```bash
kubectl get challenges -A
kubectl describe challenge <challenge-name> -n mattermost
```

Make sure you created the temporary HTTPRoute for the ACME solver.

### MinIO Tenant Not Healthy

Check PVCs:

```bash
kubectl get pvc -n mattermost-minio
```

They should use `azureblob-nfs-premium` storage class.

### Mattermost Pods Not Starting

Check pod logs:

```bash
kubectl get pods -n mattermost
kubectl logs <pod-name> -n mattermost
```

## Cleanup

Delete all resources:

```bash
az group delete --name $RESOURCE_GROUP --yes
```

## Automated Deployment

For an automated deployment script, see: [mattermost-aks-deploy](https://github.com/mattermost/mattermost-aks-deploy)
