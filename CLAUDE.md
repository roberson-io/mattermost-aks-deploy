# Claude Code Context for Mattermost Azure Kubernetes

This file provides context for Claude Code when working with this repository.

## Repository Purpose

This repository contains **automated deployment scripts** for running Mattermost on Azure Kubernetes Service (AKS). It is a companion to the [Mattermost-azure-kubernetes](../Mattermost-azure-kubernetes) repository which contains detailed manual deployment instructions.

This repo uses modern infrastructure:
- **Gateway API** instead of deprecated Ingress NGINX
- **MinIO via Kustomize** instead of deprecated kubectl-minio plugin
- **Azure Application Gateway for Containers** (native Azure Gateway API implementation)
- **Alternative storage options** (MinIO, s3proxy, NFS) with automated deployment scripts
- **Phased TLS certificate provisioning** to avoid chicken-and-egg Gateway/DNS/cert issues

## Current State

- **README.md** - Complete guide for automated deployments with all three storage options
- **DNS-TLS-AUTOMATION.md** - Detailed explanation of phased Gateway/DNS/TLS certificate strategy
- **PLAN.md** - Testing plan and progress tracker
- **Three deployment scripts** - Fully automated deployment for each storage method (MinIO, NFS, s3proxy)
- **Makefile** - Simple targets for all operations (deploy, test, status, teardown, logs)
- **Scripts are production-ready** and implement the phased TLS certificate strategy described in DNS-TLS-AUTOMATION.md

## Deployment Scripts

All deployment scripts are located in the `scripts/` directory.

### Script Overview

1. **scripts/deploy-minio.sh** - Complete stack deployment with MinIO storage
2. **scripts/deploy-nfs.sh** - Deploys Mattermost with Azure Files NFS storage
3. **scripts/deploy-s3proxy.sh** - Deploys Mattermost with s3proxy + Azure Blob Storage

### How Scripts Work

**scripts/deploy-minio.sh** creates the entire environment from scratch:
- AKS cluster with Azure CNI network plugin (2 nodes, Standard_D4s_v4)
- PostgreSQL Flexible Server v18 for database
- cert-manager v1.19.2 for TLS certificate management with Gateway API support
- Azure Application Gateway for Containers (ALB Controller) with managed identity
- MinIO Operator v7.1.1 via Kustomize (not Helm)
- MinIO Tenant with 2 servers, 4 volumes each (azureblob-nfs-premium 200Gi)
- Gateway API resources (Gateway with phased HTTP→HTTPS, HTTPRoute, ClusterIssuer)
- Mattermost Operator
- Mattermost v11.2.1 installation with ClusterIP service for ALB routing

**scripts/deploy-nfs.sh** and **scripts/deploy-s3proxy.sh** reuse the existing cluster and:
- Delete the current Mattermost deployment
- Create storage-specific resources
- Redeploy Mattermost configured for the new storage backend

### Makefile Targets

```bash
make deploy-minio    # Full deployment with MinIO
make deploy-nfs      # Switch to NFS storage
make deploy-s3proxy  # Switch to s3proxy + Azure Blob
make teardown        # Delete entire resource group
make status          # Show all resource status
make gateway-ip      # Get Gateway external IP
make logs-mattermost # Stream Mattermost logs
make clean           # Remove generated YAML files
```

### Configuration

All scripts require a `.env` file with secure configuration. The workflow is:

1. **Create .env with secrets**: `make env`
2. **Edit .env**: Update `DOMAIN` and `EMAIL` with your values
3. **Deploy**: `make deploy-minio`

The `.env` file contains:
```bash
# Azure Configuration
RESOURCE_GROUP=mattermost-test-rg
CLUSTER_NAME=mattermost-test-aks
LOCATION=eastus2

# PostgreSQL Configuration
POSTGRES_SERVER=mattermost-postgres
POSTGRES_PASSWORD=<generated-32-char-password>

# MinIO Configuration
MINIO_ADMIN_USER=admin
MINIO_ADMIN_PASSWORD=<generated-32-char-password>
MINIO_SERVICE_USER=mattermost
MINIO_SERVICE_PASSWORD=<generated-32-char-password>

# s3proxy Configuration
S3PROXY_PASSWORD=<generated-32-char-password>

# Gateway Configuration
DOMAIN=mattermost.example.com
EMAIL=admin@example.com

# License Configuration (optional)
LICENSE_FILE=   # Path to license file, e.g., ./license.mattermost
```

**Security features**:
- Scripts validate that `.env` exists before running
- Scripts check for placeholder passwords and refuse to run
- `generate-secrets.sh` creates strong 32-character random passwords
- `.env` is in `.gitignore` to prevent accidental commits
- No hardcoded weak passwords in scripts

## Key Architecture Decisions

### Why Azure CNI (not kubenet)?
Azure Application Gateway for Containers requires Azure CNI network plugin. Since this is for new deployments, we use Azure CNI from the start.

### Why Gateway API (not Ingress)?
- Ingress NGINX is retiring March 2026
- Gateway API is the Kubernetes-native successor
- Azure Application Gateway for Containers provides native integration

### Why Kustomize for MinIO (not Helm)?
The kubectl-minio plugin was deprecated in 2024. MinIO now recommends Kustomize for operator and tenant deployment.

### Storage Options Comparison

| Feature | MinIO | s3proxy | NFS |
|---------|-------|---------|-----|
| S3 API | Native | Translated | None |
| Complexity | Medium | Low | Low |
| Cost | Medium | Low | Medium |
| Performance | Excellent | Good | Excellent |
| Maturity | High | Medium | High |
| Use Case | Full S3 compatibility | Cost optimization | Max performance |

## Testing Workflow

1. **Deploy MinIO** → Test → Document findings in PLAN.md
2. **Deploy NFS** → Test → Compare with MinIO → Document
3. **Deploy s3proxy** → Test → Compare with others → Document
4. **Update README.md** with final recommendations

## Important Files

### Configuration Files (Required)
- `example.env` - Template configuration file with placeholders
- `minio-policy.json` - MinIO bucket policy for Mattermost service account

### Configuration Files (User-Created, Gitignored)
- `.env` - Active configuration with real passwords (create with `make env`)
- `license.mattermost` - Optional Mattermost Enterprise license file

### Generated by Scripts (Gitignored)
Scripts create these directories and files during deployment:
- `minio-tenant-kustomize/` - MinIO tenant manifests (namespace, secrets, tenant)
- `nfs-storage/` - NFS storage class and PVC
- `s3proxy/` - s3proxy deployment manifests
- `gateway-class.yaml` - Gateway API controller definition
- `cluster-issuer.yaml` - cert-manager Let's Encrypt issuer
- `mattermost-gateway.yaml` - Gateway resource (updated twice: HTTP-only, then with HTTPS)
- `mattermost-gateway-svc.yaml` - ClusterIP service for ALB routing (workaround for headless service)
- `mattermost-httproute.yaml` - HTTP routing rules for Mattermost traffic
- `mattermost-secret-postgres.yaml` - PostgreSQL connection secret
- `mattermost-secret-minio.yaml` - MinIO credentials secret
- `mattermost-secret-license.yaml` - Mattermost license secret (if LICENSE_FILE provided)
- `mattermost-installation-{minio,nfs,s3proxy}.yaml` - Storage-specific Mattermost configs

## Common Tasks

### Deploy and Test MinIO
```bash
# Deploy
make deploy-minio

# Wait for completion (5-15 minutes)
make status

# Get Gateway IP
make gateway-ip

# Test
kubectl get mm -n mattermost
kubectl get gateway mattermost-gateway -n mattermost
kubectl get certificate -n mattermost

# View logs
make logs-mattermost
```

### Switch to NFS Storage
```bash
# Deploy NFS (deletes existing Mattermost)
make deploy-nfs

# Verify PVC
kubectl get pvc -n mattermost

# Check volume mount
kubectl exec -n mattermost deployment/mattermost -- df -h /mattermost/data

# Test file operations
make logs-mattermost
```

### Switch to s3proxy Storage
```bash
# Deploy s3proxy
make deploy-s3proxy

# Verify s3proxy
kubectl get pods -n s3proxy
make logs-s3proxy

# Check Azure Storage
az storage blob list --account-name <name> --container-name mattermost

# Test file operations
make logs-mattermost
```

### Troubleshooting

**Gateway not getting IP:**
```bash
kubectl logs -n azure-alb-system deployment/alb-controller
kubectl describe gateway mattermost-gateway -n mattermost
```

**Certificate not provisioning:**
```bash
kubectl logs -n cert-manager deployment/cert-manager
kubectl describe certificate mattermost-tls-cert -n mattermost
```

**Mattermost not starting:**
```bash
make logs-mattermost
kubectl describe mm mattermost -n mattermost
kubectl logs -n mattermost-operator deployment/mattermost-operator
```

**MinIO tenant issues:**
```bash
kubectl get pods -n mattermost-minio
kubectl describe tenant minio-mattermost -n mattermost-minio
kubectl logs -n minio-operator deployment/minio-operator
```

## Phased TLS Certificate Provisioning

The deploy-minio.sh script implements a phased approach to avoid chicken-and-egg problems:

1. **Phase 1**: Create HTTP-only Gateway → Gets external IP
2. **Phase 2**: Script pauses and prompts user to configure DNS
3. **Phase 3**: Create Certificate resource → Let's Encrypt HTTP-01 challenge via port 80
4. **Phase 4**: Add HTTPS listener to Gateway → References now-existing TLS secret

See [DNS-TLS-AUTOMATION.md](DNS-TLS-AUTOMATION.md) for detailed explanation.

## Next Steps After Testing

1. Document findings in PLAN.md for each storage method
2. Compare performance, cost, and complexity
3. Create blog post or guide based on testing results

## Cost Considerations

**Estimated daily costs (East US 2):**
- AKS cluster (2 Standard_D4s_v4 nodes): ~$5.76/day
- PostgreSQL Flexible Server (Burstable B1ms): ~$0.72/day
- MinIO storage (azureblob-nfs-premium 200Gi): ~$1.00/day
- NFS storage (Azure Files Premium 200Gi): ~$1.00/day
- Azure Storage Account (s3proxy): Pay per usage

**Total: ~$8-10/day depending on storage option**

**Important:** Run `make teardown` when done to avoid ongoing charges!

## References

- [Gateway API Getting Started](https://gateway-api.sigs.k8s.io/guides/getting-started/)
- [Azure Application Gateway for Containers](https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/overview)
- [MinIO Operator Kustomize](https://github.com/minio/operator?tab=readme-ov-file#1-install-the-minio-operator-via-kustomization)
- [Ingress NGINX Retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- [Mattermost Operator](https://github.com/mattermost/mattermost-operator)

## Script Maintenance Notes

### If Azure CLI commands change:
- Update `az aks create` flags in all three scripts (scripts/*.sh)
- Update `az postgres flexible-server create` command in scripts/deploy-minio.sh
- Update `az storage account create` in scripts/deploy-s3proxy.sh

### If Kubernetes versions change:
- Update cert-manager version URL (currently v1.19.2) in scripts/deploy-minio.sh
- Update MinIO operator version (currently v7.1.1) in scripts/deploy-minio.sh
- Update Mattermost version in installation YAMLs (currently 11.2.1) in all three scripts

### If Gateway API changes:
- Update gateway-class.yaml generation in all three scripts
- Update HTTPRoute timeouts or policies as needed in all three scripts
- Update cert-manager integration if HTTP-01 challenge changes in all three scripts

## Development Workflow

When making changes to scripts:

1. Test on a clean deployment: `make clean && make deploy-minio`
2. Verify idempotency: Run script twice, second run should skip existing resources
3. Test teardown: `make teardown` should cleanly remove everything
4. Update PLAN.md with any findings
5. Keep scripts in sync (all three should use same base configuration)

## Security Notes

**Current Implementation:**
- Scripts generate strong 32-character random passwords via `generate-secrets.sh`
- `.env` file is gitignored to prevent credential leaks
- Scripts validate that `.env` exists and passwords are not placeholders before running
- TLS certificates are from Let's Encrypt (production-ready)
- PostgreSQL uses `--public-access 0.0.0.0` (allows Azure service IPs, not public internet)

**For Production Deployments:**
- Use Azure Key Vault for secret management
- Enable Pod Security Standards (Restricted profile)
- Configure network policies for pod-to-pod communication
- Use private endpoints for PostgreSQL Flexible Server
- Enable AKS managed identity for pod identities
- Implement Azure Policy for governance
- Enable Azure Monitor and Container Insights for observability
