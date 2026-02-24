#!/bin/bash
set -euo pipefail

# GCP Infrastructure Setup for Make Nashville Wiki
# Supports both initial deployment and updates

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env.production"

# ============================================
# Load configuration from .env.production
# ============================================
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env.production not found"
    echo "Copy .env.production.example to .env.production and fill in your values"
    exit 1
fi

echo "Loading configuration from .env.production..."
set -a
source "$ENV_FILE"
set +a

# ============================================
# Validate required fields
# ============================================
REQUIRED_VARS=(PROJECT_ID DOMAIN GCS_BUCKET GCS_ACCESS_KEY GCS_SECRET_KEY)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is required in .env.production"
        exit 1
    fi
done

# Set defaults
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
INSTANCE_NAME="${INSTANCE_NAME:-make-nashville-wiki}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-medium}"

# Auto-generate secrets if not provided
SECRET_KEY="${SECRET_KEY:-$(openssl rand -hex 32)}"
UTILS_SECRET="${UTILS_SECRET:-$(openssl rand -hex 32)}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=')}"

# ============================================
# Check if instance exists
# ============================================
gcloud config set project "$PROJECT_ID"

INSTANCE_EXISTS=$(gcloud compute instances list \
    --filter="name=$INSTANCE_NAME AND zone:$ZONE" \
    --format="value(name)" 2>/dev/null || echo "")

if [[ -n "$INSTANCE_EXISTS" ]]; then
    echo ""
    echo "============================================"
    echo "Updating existing instance: $INSTANCE_NAME"
    echo "============================================"
    echo "Domain: $DOMAIN"
    echo ""

    # Update instance metadata
    echo "Updating instance metadata..."
    gcloud compute instances add-metadata "$INSTANCE_NAME" \
        --zone="$ZONE" \
        --metadata=\
domain="$DOMAIN",\
secret-key="$SECRET_KEY",\
utils-secret="$UTILS_SECRET",\
postgres-password="$POSTGRES_PASSWORD",\
gcs-access-key="$GCS_ACCESS_KEY",\
gcs-secret-key="$GCS_SECRET_KEY",\
gcs-bucket="$GCS_BUCKET",\
slack-client-id="${SLACK_CLIENT_ID:-}",\
slack-client-secret="${SLACK_CLIENT_SECRET:-}",\
slack-webhook-url="${SLACK_WEBHOOK_URL:-}"

    # Update GCS bucket CORS for direct browser uploads
    echo "Updating GCS bucket CORS..."
    CORS_FILE=$(mktemp)
    cat > "$CORS_FILE" << CORS
[{"origin":["https://${DOMAIN}"],"method":["GET","PUT","POST","DELETE","HEAD"],"responseHeader":["Content-Type","Authorization","Content-MD5","x-goog-resumable"],"maxAgeSeconds":3600}]
CORS
    gcloud storage buckets update "gs://$GCS_BUCKET" --cors-file="$CORS_FILE"
    rm "$CORS_FILE"

    # Upload patched S3Storage.js to server
    echo "Uploading S3Storage.js patch..."
    gcloud compute scp "$SCRIPT_DIR/S3Storage.js" "$INSTANCE_NAME:~/S3Storage.js" --zone="$ZONE"
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/S3Storage.js /opt/outline/S3Storage.js && sudo chmod 644 /opt/outline/S3Storage.js'

    # Re-run configuration on the server
    echo "Applying configuration on server..."
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='
        cd /opt/outline

        # Fetch new metadata
        METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
        METADATA_HEADER="Metadata-Flavor: Google"

        get_metadata() {
            curl -sf -H "$METADATA_HEADER" "$METADATA_URL/$1" || echo ""
        }

        DOMAIN=$(get_metadata "domain")
        SECRET_KEY=$(get_metadata "secret-key")
        UTILS_SECRET=$(get_metadata "utils-secret")
        POSTGRES_PASSWORD=$(get_metadata "postgres-password")
        GCS_ACCESS_KEY=$(get_metadata "gcs-access-key")
        GCS_SECRET_KEY=$(get_metadata "gcs-secret-key")
        GCS_BUCKET=$(get_metadata "gcs-bucket")
        SLACK_CLIENT_ID=$(get_metadata "slack-client-id")
        SLACK_CLIENT_SECRET=$(get_metadata "slack-client-secret")
        SLACK_WEBHOOK_URL=$(get_metadata "slack-webhook-url")

        echo "Updating configuration for domain: $DOMAIN"

        # Update Caddyfile
        sudo tee Caddyfile > /dev/null <<CADDY
${DOMAIN} {
	header {
		X-Frame-Options SAMEORIGIN
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}
	reverse_proxy outline:3000
}
CADDY

        # Update .env file
        sudo tee .env > /dev/null <<ENV
# Domain Configuration
DOMAIN=${DOMAIN}
URL=https://${DOMAIN}

# Outline
NODE_ENV=production
APP_NAME=Make Nashville Wiki
SECRET_KEY=${SECRET_KEY}
UTILS_SECRET=${UTILS_SECRET}
PORT=3000
HOST=0.0.0.0

# Database
DATABASE_URL=postgres://outline:${POSTGRES_PASSWORD}@postgres:5432/outline
PGSSLMODE=disable
POSTGRES_USER=outline
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=outline

# Redis
REDIS_URL=redis://redis:6379

# Storage (Google Cloud Storage)
FILE_STORAGE=s3
FILE_STORAGE_UPLOAD_MAX_SIZE=52428800
AWS_S3_UPLOAD_BUCKET_NAME=${GCS_BUCKET}
AWS_S3_ACL=private

AWS_ACCESS_KEY_ID=${GCS_ACCESS_KEY}
AWS_SECRET_ACCESS_KEY=${GCS_SECRET_KEY}
AWS_REGION=auto
AWS_S3_UPLOAD_BUCKET_URL=https://storage.googleapis.com
AWS_S3_FORCE_PATH_STYLE=true

# Authentication (Slack)
SLACK_CLIENT_ID=${SLACK_CLIENT_ID}
SLACK_CLIENT_SECRET=${SLACK_CLIENT_SECRET}
ENV

        sudo chmod 600 .env

        # Update docker-compose.yml to ensure S3Storage.js volume mount is present
        sudo tee docker-compose.yml > /dev/null <<COMPOSE
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    environment:
      - DOMAIN=${DOMAIN}
    depends_on:
      - outline

  outline:
    image: docker.getoutline.com/outlinewiki/outline:1.4.0
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./S3Storage.js:/opt/outline/build/server/storage/files/S3Storage.js:ro
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    env_file: .env
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "outline"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  postgres_data:
  caddy_data:
  caddy_config:
COMPOSE

        # Write backup script
        sudo tee /opt/outline/backup.sh > /dev/null <<BACKUPSCRIPT
#!/bin/bash
set -euo pipefail

BUCKET="gs://make-nashville-wiki-uploads/backups"
TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="/tmp/outline-\${TIMESTAMP}.sql.gz"
RETAIN_DAYS=14
WEBHOOK_URL="${SLACK_WEBHOOK_URL}"

notify_failure() {
  [ -z "\${WEBHOOK_URL}" ] && return
  curl -s -X POST "\${WEBHOOK_URL}" \
    -H 'Content-type: application/json' \
    --data "{\"text\":\":warning: Outline backup failed at \$(date). Check logs on make-nashville-wiki.\"}"
}
trap notify_failure ERR

docker compose -f /opt/outline/docker-compose.yml exec -T postgres pg_dump -U outline outline | gzip > "\${BACKUP_FILE}"
gcloud storage cp "\${BACKUP_FILE}" "\${BUCKET}/outline-\${TIMESTAMP}.sql.gz"
rm -f "\${BACKUP_FILE}"

cutoff=\$(date -d "-\${RETAIN_DAYS} days" +%s)
gcloud storage ls -l "\${BUCKET}/" 2>/dev/null | while read -r line; do
  file=\$(echo "\$line" | awk "{print \\\$NF}")
  case "\$file" in gs://*) ;; *) continue ;; esac
  created=\$(echo "\$line" | awk "{print \\\$2}")
  file_epoch=\$(date -d "\$created" +%s 2>/dev/null || echo 0)
  if [[ "\$file_epoch" -gt 0 && "\$file_epoch" -lt "\$cutoff" ]]; then
    gcloud storage rm "\$file"
  fi
done

echo "[\$(date)] Backup complete: outline-\${TIMESTAMP}.sql.gz"
BACKUPSCRIPT
        sudo chmod +x /opt/outline/backup.sh

        # Ensure backup cron job is set up (idempotent)
        (sudo crontab -l 2>/dev/null | grep -v "backup.sh" || true; echo "0 3 * * * /opt/outline/backup.sh >> /var/log/outline-backup.log 2>&1") | sudo crontab -

        # Restart services to pick up new config
        echo "Restarting services..."
        sudo docker compose down
        sudo docker compose up -d

        echo "Update complete!"
    '

    STATIC_IP=$(gcloud compute addresses describe "$INSTANCE_NAME-ip" \
        --region="$REGION" \
        --format="value(address)" 2>/dev/null || echo "unknown")

    echo ""
    echo "============================================"
    echo "Update complete!"
    echo "============================================"
    echo ""
    echo "Static IP: $STATIC_IP"
    echo "New Domain: $DOMAIN"
    echo ""
    echo "NEXT STEPS:"
    echo "1. Update DNS A record for '$DOMAIN' to: $STATIC_IP"
    echo "2. Wait for DNS propagation and Let's Encrypt certificate"
    echo "3. Visit: https://$DOMAIN"
    echo ""
    echo "Check logs:"
    echo "  gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --command='cd /opt/outline && sudo docker compose logs -f'"

    exit 0
fi

# ============================================
# New installation
# ============================================

echo ""
echo "============================================"
echo "GCP Setup for Make Nashville Wiki"
echo "============================================"
echo "Project: $PROJECT_ID"
echo "Region: $REGION"
echo "Zone: $ZONE"
echo "Domain: $DOMAIN"
echo "Machine: $MACHINE_TYPE"
echo ""

# Enable required APIs
echo "Enabling required APIs..."
gcloud services enable compute.googleapis.com
gcloud services enable storage.googleapis.com

# Create GCS bucket for file uploads
echo "Creating GCS bucket..."
gcloud storage buckets create "gs://$GCS_BUCKET" \
    --location="$REGION" \
    --uniform-bucket-level-access \
    2>/dev/null || echo "Bucket already exists or name taken"

# Configure GCS bucket CORS for direct browser uploads
echo "Configuring GCS bucket CORS..."
CORS_FILE=$(mktemp)
cat > "$CORS_FILE" << CORS
[{"origin":["https://${DOMAIN}"],"method":["GET","PUT","POST","DELETE","HEAD"],"responseHeader":["Content-Type","Authorization","Content-MD5","x-goog-resumable"],"maxAgeSeconds":3600}]
CORS
gcloud storage buckets update "gs://$GCS_BUCKET" --cors-file="$CORS_FILE"
rm "$CORS_FILE"

# Create firewall rules for HTTP/HTTPS
echo "Creating firewall rules..."
gcloud compute firewall-rules create allow-http \
    --allow tcp:80 \
    --target-tags=http-server \
    --description="Allow HTTP traffic" \
    2>/dev/null || echo "HTTP firewall rule already exists"

gcloud compute firewall-rules create allow-https \
    --allow tcp:443 \
    --target-tags=https-server \
    --description="Allow HTTPS traffic" \
    2>/dev/null || echo "HTTPS firewall rule already exists"

# Reserve static external IP
echo "Reserving static IP..."
gcloud compute addresses create "$INSTANCE_NAME-ip" \
    --region="$REGION" \
    2>/dev/null || echo "Static IP already reserved"

STATIC_IP=$(gcloud compute addresses describe "$INSTANCE_NAME-ip" \
    --region="$REGION" \
    --format="value(address)")
echo "Static IP: $STATIC_IP"

# Create the VM instance
echo "Creating Compute Engine instance..."
gcloud compute instances create "$INSTANCE_NAME" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --boot-disk-size=50GB \
    --boot-disk-type=pd-balanced \
    --tags=http-server,https-server \
    --address="$STATIC_IP" \
    --metadata-from-file=startup-script="$SCRIPT_DIR/startup.sh" \
    --metadata=\
domain="$DOMAIN",\
secret-key="$SECRET_KEY",\
utils-secret="$UTILS_SECRET",\
postgres-password="$POSTGRES_PASSWORD",\
gcs-access-key="$GCS_ACCESS_KEY",\
gcs-secret-key="$GCS_SECRET_KEY",\
gcs-bucket="$GCS_BUCKET",\
slack-client-id="${SLACK_CLIENT_ID:-}",\
slack-client-secret="${SLACK_CLIENT_SECRET:-}",\
slack-webhook-url="${SLACK_WEBHOOK_URL:-}"

echo ""
echo "============================================"
echo "Setup complete!"
echo "============================================"
echo ""
echo "Static IP: $STATIC_IP"
echo "Domain: $DOMAIN"
echo ""
echo "NEXT STEPS:"
echo "1. Point your DNS A record for '$DOMAIN' to: $STATIC_IP"
echo "2. Wait 5-10 minutes for the server to initialize"
echo "3. Check startup progress:"
echo "   gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --command='sudo tail -f /var/log/outline-setup.log'"
echo ""
echo "4. Once DNS propagates, visit: https://$DOMAIN"
echo ""
echo "SAVE THESE SECRETS (they won't be shown again):"
echo "  SECRET_KEY=$SECRET_KEY"
echo "  UTILS_SECRET=$UTILS_SECRET"
echo "  POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
echo ""
echo "USEFUL COMMANDS:"
echo "  # SSH into server"
echo "  gcloud compute ssh $INSTANCE_NAME --zone=$ZONE"
echo ""
echo "  # View logs"
echo "  gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --command='cd /opt/outline && sudo docker compose logs -f'"
echo ""
echo "  # Restart services"
echo "  gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --command='cd /opt/outline && sudo docker compose restart'"
echo ""
echo "  # Update configuration (after editing .env.production)"
echo "  ./gcloud-setup.sh"
echo ""
echo "  # Delete instance (WARNING: destroys data)"
echo "  gcloud compute instances delete $INSTANCE_NAME --zone=$ZONE"
