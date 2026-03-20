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
KUTT_DB_PASSWORD="${KUTT_DB_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=')}"
KUTT_JWT_SECRET="${KUTT_JWT_SECRET:-$(openssl rand -hex 32)}"

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
slack-webhook-url="${SLACK_WEBHOOK_URL:-}",\
kutt-db-password="$KUTT_DB_PASSWORD",\
kutt-jwt-secret="$KUTT_JWT_SECRET",\
oauth2-client-id="${OAUTH2_PROXY_CLIENT_ID:-}",\
oauth2-client-secret="${OAUTH2_PROXY_CLIENT_SECRET:-}",\
oauth2-cookie-secret="${OAUTH2_PROXY_COOKIE_SECRET:-}",\
oauth2-google-group="${OAUTH2_PROXY_GOOGLE_GROUPS:-}",\
oauth2-google-admin-email="${OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL:-}"

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

    # Upload Kutt files
    echo "Uploading Kutt files..."
    gcloud compute scp "$SCRIPT_DIR/init-kutt-db.sql" "$INSTANCE_NAME:~/init-kutt-db.sql" --zone="$ZONE"
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/init-kutt-db.sql /opt/outline/init-kutt-db.sql && sudo chmod 644 /opt/outline/init-kutt-db.sql'

    # Upload Google service account key for oauth2-proxy (required for Google Group access control)
    if [[ -f "$SCRIPT_DIR/google-sa-key.json" ]]; then
        echo "Uploading Google service account key..."
        gcloud compute scp "$SCRIPT_DIR/google-sa-key.json" "$INSTANCE_NAME:~/google-sa-key.json" --zone="$ZONE"
        gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/google-sa-key.json /opt/outline/google-sa-key.json && sudo chmod 644 /opt/outline/google-sa-key.json'
    fi

    # Re-run configuration on the server
    echo "Applying configuration on server..."
    REMOTE_SCRIPT=$(mktemp)
    cat > "$REMOTE_SCRIPT" <<'SSHEOF'
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
        KUTT_DB_PASSWORD=$(get_metadata "kutt-db-password")
        KUTT_JWT_SECRET=$(get_metadata "kutt-jwt-secret")
        OAUTH2_CLIENT_ID=$(get_metadata "oauth2-client-id")
        OAUTH2_CLIENT_SECRET=$(get_metadata "oauth2-client-secret")
        OAUTH2_COOKIE_SECRET=$(get_metadata "oauth2-cookie-secret")
        OAUTH2_GOOGLE_GROUP=$(get_metadata "oauth2-google-group")
        OAUTH2_GOOGLE_ADMIN_EMAIL=$(get_metadata "oauth2-google-admin-email")

        # Create Kutt database if it doesn't exist on existing Postgres instances
        echo "Ensuring Kutt database exists..."
        sudo docker compose exec -T postgres psql -U outline -tc "SELECT 1 FROM pg_roles WHERE rolname='kutt'" | grep -q 1 || \
            sudo docker compose exec -T postgres psql -U outline -c "CREATE USER kutt WITH PASSWORD '${KUTT_DB_PASSWORD}';"
        sudo docker compose exec -T postgres psql -U outline -tc "SELECT 1 FROM pg_database WHERE datname='kutt'" | grep -q 1 || \
            sudo docker compose exec -T postgres psql -U outline -c "CREATE DATABASE kutt OWNER kutt;"

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

to.makenashville.org {
	header {
		X-Frame-Options SAMEORIGIN
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}

	handle /oauth2/* {
		reverse_proxy oauth2-proxy:4180
	}

	@protected {
		path / /api /api/*
	}
	handle @protected {
		forward_auth oauth2-proxy:4180 {
			uri /oauth2/auth
			header_up X-Forwarded-Host {host}
			copy_headers X-Auth-Request-User X-Auth-Request-Email
			@unauthorized {
				status 401
			}
			handle_response @unauthorized {
				redir * https://to.makenashville.org/oauth2/start?rd={scheme}://{host}{uri}
			}
		}
		reverse_proxy kutt:3001
	}

	handle {
		reverse_proxy kutt:3001
	}
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

        # Write kutt.env with production values
        sudo tee kutt.env > /dev/null <<KUTTENV
DEFAULT_DOMAIN=to.makenashville.org
PORT=3001
SITE_NAME=Make Nashville Links
DB_CLIENT=pg
DB_HOST=postgres
DB_PORT=5432
DB_NAME=kutt
DB_USER=kutt
DB_PASSWORD=${KUTT_DB_PASSWORD}
REDIS_ENABLED=true
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_DB=1
JWT_SECRET=${KUTT_JWT_SECRET}
DISALLOW_REGISTRATION=true
DISALLOW_ANONYMOUS_LINKS=true
DISALLOW_LOGIN_FORM=true
MAIL_ENABLED=false
ADMIN_EMAILS=admin@makenashville.org
TRUST_PROXY=true
KUTTENV
        sudo chmod 600 kutt.env

        # Update docker-compose.yml
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
      outline:
        condition: service_healthy
      oauth2-proxy:
        condition: service_started
      kutt:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO /dev/null http://localhost:2019/config/ || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 5

  outline:
    image: docker.getoutline.com/outlinewiki/outline:1.4.0
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./S3Storage.js:/opt/outline/build/server/storage/files/S3Storage.js:ro
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://localhost:3000/_health').then(r=>{process.exit(r.ok?0:1)}).catch(()=>process.exit(1))\""]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 30s
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  kutt:
    image: kutt/kutt:v3.2.3
    restart: unless-stopped
    env_file: kutt.env
    healthcheck:
      test: ["CMD-SHELL", "wget -qO /dev/null http://localhost:3001/api/v2/health || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 30s
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.7.1
    restart: unless-stopped
    volumes:
      - ./google-sa-key.json:/etc/oauth2-proxy/google-sa-key.json:ro
    environment:
      - OAUTH2_PROXY_PROVIDER=google
      - OAUTH2_PROXY_CLIENT_ID=${OAUTH2_CLIENT_ID}
      - OAUTH2_PROXY_CLIENT_SECRET=${OAUTH2_CLIENT_SECRET}
      - OAUTH2_PROXY_COOKIE_SECRET=${OAUTH2_COOKIE_SECRET}
      - OAUTH2_PROXY_COOKIE_SECURE=true
      - OAUTH2_PROXY_EMAIL_DOMAINS=makenashville.org
      - OAUTH2_PROXY_GOOGLE_GROUPS=${OAUTH2_GOOGLE_GROUP}
      - OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL=${OAUTH2_GOOGLE_ADMIN_EMAIL}
      - OAUTH2_PROXY_GOOGLE_SERVICE_ACCOUNT_JSON=/etc/oauth2-proxy/google-sa-key.json
      - OAUTH2_PROXY_REDIRECT_URL=https://to.makenashville.org/oauth2/callback
      - OAUTH2_PROXY_UPSTREAM=static://202
      - OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
      - OAUTH2_PROXY_REVERSE_PROXY=true

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    env_file: .env
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-kutt-db.sql:/docker-entrypoint-initdb.d/init-kutt-db.sql:ro
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
    -H "Content-type: application/json" \
    --data "{\"text\":\":warning: Backup failed at \$(date). Check logs on make-nashville-wiki.\"}"
}
trap notify_failure ERR

docker compose -f /opt/outline/docker-compose.yml exec -T postgres pg_dump -U outline outline | gzip > "\${BACKUP_FILE}"
gcloud storage cp "\${BACKUP_FILE}" "\${BUCKET}/outline-\${TIMESTAMP}.sql.gz"
rm -f "\${BACKUP_FILE}"

# Backup Kutt database
KUTT_BACKUP_FILE="/tmp/kutt-\${TIMESTAMP}.sql.gz"
docker compose -f /opt/outline/docker-compose.yml exec -T postgres pg_dump -U kutt kutt | gzip > "\${KUTT_BACKUP_FILE}"
gcloud storage cp "\${KUTT_BACKUP_FILE}" "\${BUCKET}/kutt-\${TIMESTAMP}.sql.gz"
rm -f "\${KUTT_BACKUP_FILE}"

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

echo "[\$(date)] Backup complete: outline and kutt \${TIMESTAMP}"
BACKUPSCRIPT
        sudo chmod +x /opt/outline/backup.sh

        # Ensure backup cron job is set up (idempotent)
        (sudo crontab -l 2>/dev/null | grep -v "backup.sh" || true; echo "0 3 * * * /opt/outline/backup.sh >> /var/log/outline-backup.log 2>&1") | sudo crontab -

        # Restart services to pick up new config
        echo "Restarting services..."
        sudo docker compose down
        sudo docker compose up -d

        echo "Update complete!"
SSHEOF
    gcloud compute scp "$REMOTE_SCRIPT" "$INSTANCE_NAME:~/update-config.sh" --zone="$ZONE"
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo bash ~/update-config.sh && rm ~/update-config.sh'
    rm "$REMOTE_SCRIPT"

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
slack-webhook-url="${SLACK_WEBHOOK_URL:-}",\
kutt-db-password="$KUTT_DB_PASSWORD",\
kutt-jwt-secret="$KUTT_JWT_SECRET",\
oauth2-client-id="${OAUTH2_PROXY_CLIENT_ID:-}",\
oauth2-client-secret="${OAUTH2_PROXY_CLIENT_SECRET:-}",\
oauth2-cookie-secret="${OAUTH2_PROXY_COOKIE_SECRET:-}",\
oauth2-google-group="${OAUTH2_PROXY_GOOGLE_GROUPS:-}",\
oauth2-google-admin-email="${OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL:-}"

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
echo "SAVE THESE SECRETS - they will not be shown again:"
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
