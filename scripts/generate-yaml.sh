#!/bin/bash
set -e

# Generate all YAML files from templates
# This script reads from .env and generates YAML files in yaml/ directory
# Usage: ./scripts/generate-yaml.sh

# Load environment variables
if [ ! -f .env ]; then
    echo "ERROR: .env file not found!"
    exit 1
fi

source .env

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$REPO_ROOT/templates"
YAML_DIR="$REPO_ROOT/yaml"

# Create yaml directory
mkdir -p "$YAML_DIR"

echo "Generating YAML files from templates..."
echo "  Templates directory: $TEMPLATES_DIR"
echo "  Output directory: $YAML_DIR"
echo ""

# ====================================================================================
# Gateway API Resources
# ====================================================================================

echo "Generating Gateway API resources..."

# Gateway Class (static file)
cp "$TEMPLATES_DIR/gateway-class.yaml" "$YAML_DIR/gateway-class.yaml"

# Gateway Service (static file)
cp "$TEMPLATES_DIR/mattermost-gateway-svc.yaml" "$YAML_DIR/mattermost-gateway-svc.yaml"

# Cluster Issuer (requires EMAIL)
export EMAIL
envsubst < "$TEMPLATES_DIR/cluster-issuer.yaml.tmpl" > "$YAML_DIR/cluster-issuer.yaml"

echo "  ✓ Gateway class, gateway service, and cluster issuer created"

# ====================================================================================
# MinIO Tenant Kustomize Resources
# ====================================================================================

echo "Generating MinIO tenant resources..."

mkdir -p "$YAML_DIR/minio-tenant-kustomize"

# Static files
cp "$TEMPLATES_DIR/minio-tenant-kustomize/namespace.yaml" "$YAML_DIR/minio-tenant-kustomize/namespace.yaml"
cp "$TEMPLATES_DIR/minio-tenant-kustomize/kustomization.yaml" "$YAML_DIR/minio-tenant-kustomize/kustomization.yaml"

# Tenant credentials secret
export MINIO_ADMIN_USER
export MINIO_ADMIN_PASSWORD
export MINIO_ADMIN_USER_BASE64=$(echo -n "$MINIO_ADMIN_USER" | base64)
export MINIO_ADMIN_PASSWORD_BASE64=$(echo -n "$MINIO_ADMIN_PASSWORD" | base64)
envsubst < "$TEMPLATES_DIR/minio-tenant-kustomize/tenant-credentials-secret.yaml.tmpl" > "$YAML_DIR/minio-tenant-kustomize/tenant-credentials-secret.yaml"

# Mattermost user secret
export MINIO_SERVICE_USER
export MINIO_SERVICE_PASSWORD
export MINIO_SERVICE_USER_BASE64=$(echo -n "$MINIO_SERVICE_USER" | base64)
export MINIO_SERVICE_PASSWORD_BASE64=$(echo -n "$MINIO_SERVICE_PASSWORD" | base64)
export MINIO_ACCESS_KEY_BASE64=$(echo -n "$MINIO_SERVICE_USER" | base64)
export MINIO_SECRET_KEY_BASE64=$(echo -n "$MINIO_SERVICE_PASSWORD" | base64)
envsubst < "$TEMPLATES_DIR/minio-tenant-kustomize/mattermost-user-secret.yaml.tmpl" > "$YAML_DIR/minio-tenant-kustomize/mattermost-user-secret.yaml"

# MinIO tenant (requires MINIO_IMAGE)
export MINIO_IMAGE
envsubst < "$TEMPLATES_DIR/minio-tenant-kustomize/tenant.yaml.tmpl" > "$YAML_DIR/minio-tenant-kustomize/tenant.yaml"

echo "  ✓ MinIO tenant resources created"

# ====================================================================================
# Mattermost Secrets
# ====================================================================================

echo "Generating Mattermost secrets..."

# PostgreSQL secret
export POSTGRES_SERVER
export POSTGRES_DB
export POSTGRES_ADMIN_USER
export POSTGRES_PASSWORD
export CONNECTION_STRING="postgres://${POSTGRES_ADMIN_USER}:${POSTGRES_PASSWORD}@${POSTGRES_SERVER}.postgres.database.azure.com:5432/${POSTGRES_DB}?sslmode=require&connect_timeout=10"
export CONNECTION_STRING_BASE64=$(echo -n "$CONNECTION_STRING" | base64)
envsubst < "$TEMPLATES_DIR/mattermost-secret-postgres.yaml.tmpl" > "$YAML_DIR/mattermost-secret-postgres.yaml"

# MinIO secret (uses MINIO_ACCESS_KEY_BASE64 and MINIO_SECRET_KEY_BASE64 from above)
envsubst < "$TEMPLATES_DIR/mattermost-secret-minio.yaml.tmpl" > "$YAML_DIR/mattermost-secret-minio.yaml"

# License secret (if LICENSE_FILE is set and exists)
if [ -n "$LICENSE_FILE" ] && [ -f "$LICENSE_FILE" ]; then
    export LICENSE_CONTENT_BASE64=$(base64 < "$LICENSE_FILE" | tr -d '\n')
    envsubst < "$TEMPLATES_DIR/mattermost-secret-license.yaml.tmpl" > "$YAML_DIR/mattermost-secret-license.yaml"
    echo "  ✓ PostgreSQL, MinIO, and license secrets created"
else
    echo "  ✓ PostgreSQL and MinIO secrets created (no license file)"
fi

# ====================================================================================
# Mattermost Installation
# ====================================================================================

echo "Generating Mattermost installation manifests..."

export DOMAIN
export MATTERMOST_VERSION
export MATTERMOST_SIZE
export MM_SERVICEENVIRONMENT
export MM_FILESETTINGS_AMAZONS3SSL
export MM_FILESETTINGS_AMAZONS3SSE
export MM_FILESETTINGS_AMAZONS3TRACE
export MINIO_SERVICE_USER  # Already exported above
envsubst < "$TEMPLATES_DIR/mattermost-installation-minio.yaml.tmpl" > "$YAML_DIR/mattermost-installation-minio.yaml"

echo "  ✓ Mattermost installation manifest created"

echo ""
echo "=============================================="
echo "  YAML Generation Complete!"
echo "=============================================="
echo ""
echo "Generated files in $YAML_DIR:"
echo "  - Gateway API resources (gateway-class, cluster-issuer)"
echo "  - MinIO tenant resources (minio-tenant-kustomize/)"
echo "  - Mattermost secrets (postgres, minio, license)"
echo "  - Mattermost installation (mattermost-installation-minio.yaml)"
echo ""
echo "Note: Gateway, HTTPRoute, and Certificate resources require deployment-time"
echo "      values (ALB ID, Gateway IP, solver service) and are generated during deployment."
echo ""
