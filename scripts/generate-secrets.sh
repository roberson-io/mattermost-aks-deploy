#!/bin/bash
set -e

# Generate strong random secrets for Mattermost deployment
# Usage: ./scripts/generate-secrets.sh

echo "Generating secure secrets..."

# Check if pwgen is installed
if ! command -v pwgen &> /dev/null; then
    echo "ERROR: pwgen is not installed."
    echo ""
    echo "Please install pwgen:"
    echo "  macOS:  brew install pwgen"
    echo "  Ubuntu: sudo apt-get install pwgen"
    echo ""
    exit 1
fi

# Function to generate a strong password
generate_password() {
    pwgen -s 32 1
}

# Check if .env already exists
if [ -f .env ]; then
    echo ""
    echo "WARNING: .env file already exists!"
    read -p "Do you want to overwrite it? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted. Keeping existing .env file."
        exit 0
    fi
fi

# Generate secrets
POSTGRES_PASSWORD=$(generate_password)
MINIO_ADMIN_PASSWORD=$(generate_password)
MINIO_SERVICE_PASSWORD=$(generate_password)
S3PROXY_PASSWORD=$(generate_password)

# Create .env from example.env
if [ ! -f example.env ]; then
    echo "ERROR: example.env not found. Please ensure it exists in the current directory."
    exit 1
fi

# Copy example and replace placeholders
cat example.env | \
    sed "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" | \
    sed "s|MINIO_ADMIN_PASSWORD=.*|MINIO_ADMIN_PASSWORD=$MINIO_ADMIN_PASSWORD|" | \
    sed "s|MINIO_SERVICE_PASSWORD=.*|MINIO_SERVICE_PASSWORD=$MINIO_SERVICE_PASSWORD|" | \
    sed "s|S3PROXY_PASSWORD=.*|S3PROXY_PASSWORD=$S3PROXY_PASSWORD|" \
    > .env

echo ""
echo "✓ Generated .env file with secure secrets"
echo ""
echo "Generated passwords (32 characters each):"
echo "  - PostgreSQL password"
echo "  - MinIO admin password"
echo "  - MinIO service account password"
echo "  - s3proxy password"
echo ""
echo "IMPORTANT:"
echo "  - Review .env and update DOMAIN and EMAIL with your values"
echo "  - Never commit .env to git (already in .gitignore)"
echo "  - Keep .env secure and backed up safely"
echo ""
