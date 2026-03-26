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
SHLINK_DB_PASSWORD="${SHLINK_DB_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=')}"
OAUTH2_PROXY_COOKIE_SECRET="${OAUTH2_PROXY_COOKIE_SECRET:-$(openssl rand -base64 32 | head -c 32)}"
MOODLE_DB_PASSWORD="${MOODLE_DB_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=')}"
MOODLE_ADMIN_PASSWORD="${MOODLE_ADMIN_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=')}"
MOODLE_WEBHOOK_SECRET="${MOODLE_WEBHOOK_SECRET:-$(openssl rand -hex 32)}"

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
shlink-db-password="$SHLINK_DB_PASSWORD",\
oauth2-client-id="${OAUTH2_PROXY_CLIENT_ID:-}",\
oauth2-client-secret="${OAUTH2_PROXY_CLIENT_SECRET:-}",\
oauth2-cookie-secret="$OAUTH2_PROXY_COOKIE_SECRET",\
oauth2-google-group="${OAUTH2_PROXY_GOOGLE_GROUPS:-}",\
oauth2-google-admin-email="${OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL:-}",\
moodle-db-password="$MOODLE_DB_PASSWORD",\
moodle-admin-password="$MOODLE_ADMIN_PASSWORD",\
moodle-admin-email="${MOODLE_ADMIN_EMAIL:-}",\
moodle-webhook-secret="$MOODLE_WEBHOOK_SECRET",\
grit-api-url="${GRIT_API_URL:-}",\
grit-api-key="${GRIT_API_KEY:-}",\
shlink-api-key="${SHLINK_API_KEY:-}"

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

    # Upload Shlink DB init script
    echo "Uploading Shlink files..."
    gcloud compute scp "$SCRIPT_DIR/init-shlink-db.sql" "$INSTANCE_NAME:~/init-shlink-db.sql" --zone="$ZONE"
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/init-shlink-db.sql /opt/outline/init-shlink-db.sql && sudo chmod 644 /opt/outline/init-shlink-db.sql'

    # Upload Google service account key for oauth2-proxy group checking
    if [[ -f "$SCRIPT_DIR/google-sa-key.json" ]]; then
        echo "Uploading Google service account key..."
        gcloud compute scp "$SCRIPT_DIR/google-sa-key.json" "$INSTANCE_NAME:~/google-sa-key.json" --zone="$ZONE"
        gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/google-sa-key.json /opt/outline/google-sa-key.json && sudo chmod 644 /opt/outline/google-sa-key.json'
    fi

    # Upload GRIT provisioner files
    echo "Uploading GRIT provisioner files..."
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mkdir -p /opt/outline/grit-provisioner'
    gcloud compute scp "$SCRIPT_DIR/grit-provisioner/server.py" "$INSTANCE_NAME:~/grit-server.py" --zone="$ZONE"
    gcloud compute scp "$SCRIPT_DIR/grit-provisioner/course-tool-map.json" "$INSTANCE_NAME:~/grit-course-tool-map.json" --zone="$ZONE"
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/grit-server.py /opt/outline/grit-provisioner/server.py && sudo mv ~/grit-course-tool-map.json /opt/outline/grit-provisioner/course-tool-map.json && sudo chmod 644 /opt/outline/grit-provisioner/*'

    # Upload Moodle Docker build files
    echo "Uploading Moodle Docker files..."
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mkdir -p /opt/outline/moodle-docker'
    gcloud compute scp "$SCRIPT_DIR/moodle/Dockerfile" "$INSTANCE_NAME:~/moodle-Dockerfile" --zone="$ZONE"
    gcloud compute scp "$SCRIPT_DIR/moodle/entrypoint.sh" "$INSTANCE_NAME:~/moodle-entrypoint.sh" --zone="$ZONE"
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/moodle-Dockerfile /opt/outline/moodle-docker/Dockerfile && sudo mv ~/moodle-entrypoint.sh /opt/outline/moodle-docker/entrypoint.sh && sudo chmod +x /opt/outline/moodle-docker/entrypoint.sh'

    # Apply configuration on server
    echo "Applying configuration on server..."
    gcloud compute scp "$SCRIPT_DIR/update-server.sh" "$INSTANCE_NAME:~/update-server.sh" --zone="$ZONE"
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo bash ~/update-server.sh && rm ~/update-server.sh'

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
shlink-db-password="$SHLINK_DB_PASSWORD",\
oauth2-client-id="${OAUTH2_PROXY_CLIENT_ID:-}",\
oauth2-client-secret="${OAUTH2_PROXY_CLIENT_SECRET:-}",\
oauth2-cookie-secret="$OAUTH2_PROXY_COOKIE_SECRET",\
oauth2-google-group="${OAUTH2_PROXY_GOOGLE_GROUPS:-}",\
oauth2-google-admin-email="${OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL:-}",\
moodle-db-password="$MOODLE_DB_PASSWORD",\
moodle-admin-password="$MOODLE_ADMIN_PASSWORD",\
moodle-admin-email="${MOODLE_ADMIN_EMAIL:-}",\
moodle-webhook-secret="$MOODLE_WEBHOOK_SECRET",\
grit-api-url="${GRIT_API_URL:-}",\
grit-api-key="${GRIT_API_KEY:-}",\
shlink-api-key="${SHLINK_API_KEY:-}"

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
echo "  MOODLE_DB_PASSWORD=$MOODLE_DB_PASSWORD"
echo "  MOODLE_ADMIN_PASSWORD=$MOODLE_ADMIN_PASSWORD"
echo "  MOODLE_WEBHOOK_SECRET=$MOODLE_WEBHOOK_SECRET"
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
