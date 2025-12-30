# DNS and TLS Automation Strategy

## Overview

This document explains how DNS configuration and TLS certificate issuance are coordinated in the Mattermost Azure Kubernetes deployment.

## The Chicken-and-Egg Problem

Azure Application Gateway for Containers (ALB) has a dependency chain that creates a coordination challenge:

1. **Gateway needs TLS secret to accept HTTPS listener** → Gateway won't be fully "Programmed" without valid TLS secret
2. **TLS certificate can't be issued without accessible HTTP endpoint** → Let's Encrypt HTTP-01 challenge requires port 80 to be accessible
3. **Port 80 isn't accessible until Gateway is "Programmed"** → Azure ALB doesn't route traffic to an invalid Gateway
4. **DNS must point to Gateway address** → But the Gateway address varies with each deployment

## Solution: Phased Deployment

### Phase 1: HTTP-Only Gateway (Automated)
```bash
# Create Gateway with only HTTP listener (no HTTPS)
kubectl apply -f gateway-http-only.yaml
```
- Gateway becomes "Programmed" immediately (no TLS secret dependency)
- Port 80 becomes accessible
- Script retrieves Gateway address

### Phase 2: DNS Configuration (Manual)
```
Script output:
  Gateway Address: b9b8fnbaczb7e8gh.fz88.alb.azure.com

  ACTION REQUIRED:
  Create DNS CNAME record:
    mm.roberson.io → b9b8fnbaczb7e8gh.fz88.alb.azure.com

  Press Enter when DNS is configured...
```

**Why manual?**
- Gateway address varies per deployment
- DNS providers differ (GoDaddy, Cloudflare, Azure DNS, Route53)
- Requires user's DNS credentials
- User may want custom DNS setup (A record, CNAME, etc.)

### Phase 3: Certificate Issuance (Automated)
```bash
# After user confirms DNS is ready
kubectl apply -f certificate.yaml
kubectl wait --for=condition=ready certificate mattermost-tls-cert
```
- Let's Encrypt performs HTTP-01 challenge via port 80
- Certificate issued automatically
- TLS secret created

### Phase 4: Add HTTPS Listener (Automated)
```bash
# Update Gateway to include HTTPS listener
kubectl apply -f gateway-with-https.yaml
```
- Gateway references now-existing TLS secret
- HTTPS listener becomes valid
- Gateway remains "Programmed"

## Implementation in deploy-minio.sh

### Current Implementation Issues

1. ❌ Gateway created with HTTPS listener before TLS secret exists
2. ❌ No DNS configuration guidance or pause
3. ❌ Certificate creation happens too early
4. ❌ ClusterIssuer uses `gatewayHTTPRoute` (experimental, doesn't work)

### Required Changes

#### Change 1: Update ClusterIssuer (Step 11)
```bash
# Use ingress solver instead of gatewayHTTPRoute
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
        ingress:
          class: gateway
EOF
```

#### Change 2: Create HTTP-Only Gateway (Step 11)
```bash
# Gateway WITHOUT https-listener
cat > mattermost-gateway.yaml <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: mattermost-gateway
  namespace: mattermost
  annotations:
    alb.networking.azure.io/alb-id: $ALB_ID
spec:
  gatewayClassName: azure-alb-external
  listeners:
  - name: http-listener
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
EOF
```

#### Change 3: Wait for Gateway and Get Address (Step 11.5)
```bash
echo "Waiting for Gateway to be programmed..."
kubectl wait --for=condition=programmed gateway mattermost-gateway -n mattermost --timeout=300s

GATEWAY_ADDRESS=$(kubectl get gateway mattermost-gateway -n mattermost -o jsonpath='{.status.addresses[0].value}')

echo ""
echo "=========================================="
echo "DNS CONFIGURATION REQUIRED"
echo "=========================================="
echo ""
echo "Gateway Address: $GATEWAY_ADDRESS"
echo ""
echo "Create a DNS CNAME record:"
echo "  $DOMAIN  →  $GATEWAY_ADDRESS"
echo ""
echo "Example commands for different DNS providers:"
echo ""
echo "Azure DNS:"
echo "  az network dns record-set cname set-record \\"
echo "    --resource-group <dns-zone-rg> \\"
echo "    --zone-name roberson.io \\"
echo "    --record-set-name mm \\"
echo "    --cname $GATEWAY_ADDRESS"
echo ""
echo "Cloudflare CLI:"
echo "  cloudflare-cli dns create $DOMAIN CNAME $GATEWAY_ADDRESS"
echo ""
echo "Manual: Log into your DNS provider and create the CNAME record"
echo ""
read -p "Press Enter after you've configured DNS..."
echo ""
echo "Verifying DNS propagation..."
if ! nslookup $DOMAIN | grep -q "$GATEWAY_ADDRESS"; then
    echo "WARNING: DNS not yet propagated. Certificate issuance may take longer."
    echo "Continuing anyway..."
fi
```

#### Change 4: Create Certificate and Wait (Step 11.6)
```bash
echo "Creating TLS certificate for Gateway..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: mattermost-tls-cert
  namespace: mattermost
spec:
  secretName: mattermost-tls-cert
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - $DOMAIN
EOF

echo "Waiting for certificate to be issued (this may take 1-2 minutes)..."
kubectl wait --for=condition=ready certificate mattermost-tls-cert -n mattermost --timeout=300s
echo "Certificate successfully issued!"
```

#### Change 5: Add HTTPS Listener to Gateway (Step 11.7)
```bash
echo "Adding HTTPS listener to Gateway..."
cat > mattermost-gateway.yaml <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: mattermost-gateway
  namespace: mattermost
  annotations:
    alb.networking.azure.io/alb-id: $ALB_ID
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

echo "Waiting for HTTPS listener to be ready..."
sleep 10
kubectl wait --for=condition=programmed gateway mattermost-gateway -n mattermost --timeout=300s
```

## License Configuration

### Environment Variables
- `MM_SERVICEENVIRONMENT=test` - Required for test licenses
- License is mounted via Kubernetes secret

### Implementation
```bash
# Check if license file is provided
if [ -n "$LICENSE_FILE" ] && [ -f "$LICENSE_FILE" ]; then
    echo "Creating license secret..."
    LICENSE_CONTENT=$(cat "$LICENSE_FILE")
    LICENSE_CONTENT_BASE64=$(echo -n "$LICENSE_CONTENT" | base64)

    cat > mattermost-secret-license.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mattermost-secret-license
  namespace: mattermost
type: Opaque
data:
  license: $LICENSE_CONTENT_BASE64
EOF
    kubectl apply -f mattermost-secret-license.yaml

    # Add to Mattermost deployment
    LICENSE_SECRET_NAME="mattermost-secret-license"
    LICENSE_ENV_VAR="- name: MM_SERVICEENVIRONMENT\n  value: \"test\""
else
    echo "No license file provided, skipping license configuration"
    LICENSE_SECRET_NAME=""
    LICENSE_ENV_VAR=""
fi
```

## Testing the Flow

### From Scratch
```bash
make env
# Edit .env: set DOMAIN and LICENSE_FILE
make deploy-minio
# Script will pause and ask for DNS configuration
# Create DNS record as instructed
# Press Enter
# Script completes automatically
```

### Verify
```bash
# Check Gateway
kubectl get gateway mattermost-gateway -n mattermost
# Should show PROGRAMMED=True

# Check Certificate
kubectl get certificate -n mattermost
# Should show READY=True

# Test HTTP (should work)
curl http://mm.roberson.io

# Test HTTPS (should work)
curl https://mm.roberson.io
```

## Benefits of This Approach

1. ✅ **No chicken-and-egg problem** - Gateway is programmed before certificate issuance
2. ✅ **Clear user guidance** - Script shows exactly what DNS record to create
3. ✅ **Flexible DNS** - Works with any DNS provider
4. ✅ **Fully automated after DNS** - Everything else happens automatically
5. ✅ **Idempotent** - Can re-run script safely
6. ✅ **License support** - Optional license configuration with test mode

## Alternative: Fully Automated (Requires DNS Provider Access)

For fully automated deployments, could use:
- Azure DNS with service principal
- Route53 with IAM credentials
- Cloudflare API token
- External-DNS controller

This requires additional configuration and credentials, so the semi-automated approach is more flexible for different environments.
