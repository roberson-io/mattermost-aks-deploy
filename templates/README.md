# Templates Directory

This directory contains YAML templates used by the deployment scripts to generate Kubernetes resources.

## Template Types

### Static Files (`.yaml`)
Files without variables that are copied directly:
- `gateway-class.yaml` - Gateway API controller definition
- `mattermost-gateway-svc.yaml` - ClusterIP service for Gateway routing
- `minio-tenant-kustomize/namespace.yaml` - MinIO namespace
- `minio-tenant-kustomize/kustomization.yaml` - Kustomize configuration

### Template Files (`.yaml.tmpl`)
Files with variables that are processed by `envsubst`:
- `cluster-issuer.yaml.tmpl` - Let's Encrypt issuer (uses `${EMAIL}`)
- `mattermost-gateway-http.yaml.tmpl` - HTTP-only Gateway (uses `${ALB_ID}`)
- `mattermost-gateway-https.yaml.tmpl` - Gateway with HTTPS (uses `${ALB_ID}`)
- `mattermost-httproute.yaml.tmpl` - HTTP routing rules (uses `${DOMAIN}`)
- `mattermost-acme-challenge.yaml.tmpl` - ACME HTTP-01 challenge route (uses `${DOMAIN}`, `${SOLVER_SVC}`)
- `mattermost-certificate.yaml.tmpl` - TLS certificate (uses `${DOMAIN}`)
- `mattermost-secret-postgres.yaml.tmpl` - PostgreSQL credentials (uses `${CONNECTION_STRING_BASE64}`)
- `mattermost-secret-minio.yaml.tmpl` - MinIO credentials (uses `${MINIO_ACCESS_KEY_BASE64}`, `${MINIO_SECRET_KEY_BASE64}`)
- `mattermost-secret-license.yaml.tmpl` - Mattermost license (uses `${LICENSE_CONTENT_BASE64}`)
- `mattermost-installation-minio.yaml.tmpl` - Mattermost installation (uses multiple variables)
- `minio-tenant-kustomize/tenant-credentials-secret.yaml.tmpl` - MinIO admin credentials
- `minio-tenant-kustomize/mattermost-user-secret.yaml.tmpl` - MinIO service account credentials
- `minio-tenant-kustomize/tenant.yaml.tmpl` - MinIO tenant definition

## Variable Syntax

Templates use `envsubst` syntax: `${VARIABLE_NAME}`

## Usage in Scripts

```bash
# For static files
cp "$TEMPLATES_DIR/gateway-class.yaml" "$YAML_DIR/gateway-class.yaml"

# For template files
export VARIABLE_NAME="value"
envsubst < "$TEMPLATES_DIR/file.yaml.tmpl" > "$YAML_DIR/file.yaml"
```

## Generated Files

All generated YAML files are written to the `yaml/` directory in the repository root, which is gitignored.
