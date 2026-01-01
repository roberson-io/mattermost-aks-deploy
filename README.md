# Mattermost AKS Automated Deployment

Automated deployment scripts for running Mattermost on Azure Kubernetes Service (AKS) with modern infrastructure:

- **Azure Application Gateway for Containers** (Gateway API)
- **cert-manager** for automated TLS certificates
- **PostgreSQL Flexible Server** for database
- **Multiple storage options**: MinIO, NFS, or s3proxy

**Note:** This is for proof-of-concept deployments of Mattermost with Enterprise or Enterprise Advanced license keys. For production deployments, please review [Available reference architectures](https://docs.mattermost.com/administration-guide/scale/scaling-for-enterprise.html#available-reference-architectures) in the Mattermost documentation to ensure you are scaling your deployment appropriately for your use case. Consult with your organization's security team to verify that your deployment configuration is sufficiently hardened for your use case.

## Quick Start

```bash
# 1. Log in to Azure
az login

# 2. Save your Mattermost license key in a file named license.mattermost

# 3. Create configuration file with secure passwords
make env

# 4. Edit .env to set your domain and email and modify default settings
vim .env

# 5. Deploy with MinIO storage
# The script will prompt to create a DNS CNAME or A record when the gateway FQDN and IP address are available
make deploy-minio
```

The script should be idempotent. If you run into an issue that causes the script to exit with an error that requires manual intervention, you should be able to run `make deploy-minio` again after resolving the issue.

## Prerequisites

- Azure CLI (`az`) installed and logged in
- `kubectl` installed
- Active Azure subscription
- Domain name with ability to configure DNS
- `pwgen` for generating secrets if you use `make env`.

## Configuration

All configuration is managed via `.env` file:

1. **Create .env**: `make env` copies `example.env` and generates secure 32-character random passwords
2. **Edit .env**: Update `DOMAIN` and `EMAIL` with your values. Verify that the `LICENSE_FILE` setting is set to a file with a valid Enterprise or Enterprise Advanced License key. Edit any other settings as applicable for your use case.

```

## Make Targets

### Deployment

- `make deploy-minio` - Deploy complete stack with MinIO storage
- `make deploy-nfs` - Deploy with NFS storage
- `make deploy-s3proxy` - Deploy with s3proxy + Azure Blob Storage

### Management

- `make status` - Show status of all resources
- `make gateway-ip` - Get Gateway external IP address
- `make teardown` - Delete entire resource group

### Testing

- `make test-minio` - Test MinIO deployment
- `make test-nfs` - Test NFS deployment
- `make test-s3proxy` - Test s3proxy deployment

### Logs

- `make logs-mattermost` - Stream Mattermost pod logs
- `make logs-minio` - Stream MinIO tenant logs
- `make logs-s3proxy` - Stream s3proxy logs

### Cleanup

- `make clean` - Remove generated YAML files

## Storage Options

### MinIO

```bash
make deploy-minio
```

- Native S3 API implementation
- Distributed storage with multiple servers
- Uses Azure Blob NFS Premium storage (200Gi)

### NFS

```bash
make deploy-nfs
```

- Direct filesystem access (no S3 translation)
- Azure Files Premium with NFS 4.1
- Simpler architecture than object storage
- Not recommended for large deployments

### s3proxy

```bash
make deploy-s3proxy
```

- Translates S3 API to Azure Blob Storage
- Not tested on large deployments

## DNS and TLS Automation

The deployment follows a phased approach for TLS certificate provisioning:

1. **Deploy HTTP-only Gateway** - Gets external IP from Azure
2. **Configure DNS** - Point your domain to the Gateway IP
3. **Request Certificate** - Let's Encrypt validates via HTTP-01 challenge
4. **Add HTTPS Listener** - Gateway serves traffic over TLS

## Troubleshooting

### Gateway not getting IP

```bash
kubectl logs -n azure-alb-system deployment/alb-controller
kubectl describe gateway mattermost-gateway -n mattermost
```

### Certificate not provisioning

```bash
kubectl logs -n cert-manager deployment/cert-manager
kubectl describe certificate mattermost-tls-cert -n mattermost
kubectl get challenges -n mattermost
```

### Mattermost not starting

```bash
make logs-mattermost
kubectl describe mm mattermost -n mattermost
kubectl logs -n mattermost-operator deployment/mattermost-operator
```

### MinIO issues

```bash
kubectl get pods -n mattermost-minio
kubectl describe tenant minio-mattermost -n mattermost-minio
kubectl logs -n minio-operator deployment/minio-operator
```

### s3proxy issues

```bash
make logs-s3proxy
kubectl describe deployment s3proxy -n s3proxy
az storage blob list --account-name <name> --container-name mattermost
```

## License

This project is provided as-is for deploying Mattermost on Azure Kubernetes Service. Mattermost itself is licensed separately.
