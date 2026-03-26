#!/bin/bash
set -euo pipefail

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
SHLINK_DB_PASSWORD=$(get_metadata "shlink-db-password")
OAUTH2_CLIENT_ID=$(get_metadata "oauth2-client-id")
OAUTH2_CLIENT_SECRET=$(get_metadata "oauth2-client-secret")
OAUTH2_COOKIE_SECRET=$(get_metadata "oauth2-cookie-secret")
OAUTH2_GOOGLE_GROUP=$(get_metadata "oauth2-google-group")
OAUTH2_GOOGLE_ADMIN_EMAIL=$(get_metadata "oauth2-google-admin-email")
N8N_DB_PASSWORD=$(get_metadata "n8n-db-password")
N8N_ENCRYPTION_KEY=$(get_metadata "n8n-encryption-key")
MOODLE_DB_PASSWORD=$(get_metadata "moodle-db-password")
MOODLE_ADMIN_PASSWORD=$(get_metadata "moodle-admin-password")
MOODLE_ADMIN_EMAIL=$(get_metadata "moodle-admin-email")
MOODLE_WEBHOOK_SECRET=$(get_metadata "moodle-webhook-secret")
GRIT_API_URL=$(get_metadata "grit-api-url")
GRIT_API_KEY=$(get_metadata "grit-api-key")
MOODLE_IMAGE_TAG=$(get_metadata "moodle-image-tag")

# Create databases if postgres is running (skip if it's down — they'll be created after restart)
if sudo docker compose exec -T postgres pg_isready -U outline > /dev/null 2>&1; then
    echo "Ensuring Shlink database exists..."
    sudo docker compose exec -T postgres psql -U outline -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='shlink') THEN CREATE USER shlink WITH PASSWORD '${SHLINK_DB_PASSWORD}'; END IF; END \$\$;"
    sudo docker compose exec -T postgres psql -U outline -c "ALTER USER shlink WITH PASSWORD '${SHLINK_DB_PASSWORD}';"
    sudo docker compose exec -T postgres psql -U outline -c "SELECT 'CREATE DATABASE shlink OWNER shlink' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='shlink')\gexec" 2>/dev/null || true

    echo "Ensuring n8n database exists..."
    sudo docker compose exec -T postgres psql -U outline -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='n8n') THEN CREATE USER n8n WITH PASSWORD '${N8N_DB_PASSWORD}'; END IF; END \$\$;"
    sudo docker compose exec -T postgres psql -U outline -c "ALTER USER n8n WITH PASSWORD '${N8N_DB_PASSWORD}';"
    sudo docker compose exec -T postgres psql -U outline -c "SELECT 'CREATE DATABASE n8n OWNER n8n' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='n8n')\gexec" 2>/dev/null || true

    echo "Ensuring Moodle database exists..."
    sudo docker compose exec -T postgres psql -U outline -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='moodle') THEN CREATE USER moodle WITH PASSWORD '${MOODLE_DB_PASSWORD}'; END IF; END \$\$;"
    sudo docker compose exec -T postgres psql -U outline -c "ALTER USER moodle WITH PASSWORD '${MOODLE_DB_PASSWORD}';"
    sudo docker compose exec -T postgres psql -U outline -c "SELECT 'CREATE DATABASE moodle OWNER moodle' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='moodle')\gexec" 2>/dev/null || true
else
    echo "Postgres not running — skipping DB creation (will retry after restart)"
fi

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

links.makenashville.org {
	header {
		X-Frame-Options SAMEORIGIN
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}

	handle /oauth2/* {
		reverse_proxy oauth2-proxy:4180
	}

	handle {
		forward_auth oauth2-proxy:4180 {
			uri /oauth2/auth
			header_up X-Forwarded-Host {host}
			copy_headers X-Auth-Request-User X-Auth-Request-Email
			@unauthorized {
				status 401
			}
			handle_response @unauthorized {
				redir * https://links.makenashville.org/oauth2/start?rd={scheme}://{host}{uri}
			}
		}
		reverse_proxy shlink-web:8080
	}
}

to.makenashville.org, go.makenashville.org {
	header {
		X-Frame-Options SAMEORIGIN
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}
	reverse_proxy shlink:8080
}

automations.makenashville.org {
	header {
		X-Frame-Options SAMEORIGIN
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}

	handle /oauth2/* {
		reverse_proxy oauth2-proxy:4180
	}

	@webhooks {
		path /webhook/* /webhook-test/*
	}
	handle @webhooks {
		reverse_proxy n8n:5678
	}

	handle {
		forward_auth oauth2-proxy:4180 {
			uri /oauth2/auth
			header_up X-Forwarded-Host {host}
			copy_headers X-Auth-Request-User X-Auth-Request-Email
			@unauthorized {
				status 401
			}
			handle_response @unauthorized {
				redir * https://automations.makenashville.org/oauth2/start?rd={scheme}://{host}{uri}
			}
		}
		reverse_proxy n8n:5678
	}
}

learn.makenashville.org {
	header {
		X-Frame-Options SAMEORIGIN
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}
	reverse_proxy moodle:80 {
		header_up Host moodle
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

# Shlink
SHLINK_DB_PASSWORD=${SHLINK_DB_PASSWORD}

# n8n
N8N_DB_PASSWORD=${N8N_DB_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

# Moodle
MOODLE_DB_PASSWORD=${MOODLE_DB_PASSWORD}
MOODLE_ADMIN_PASSWORD=${MOODLE_ADMIN_PASSWORD}
MOODLE_ADMIN_EMAIL=${MOODLE_ADMIN_EMAIL}
MOODLE_WEBHOOK_SECRET=${MOODLE_WEBHOOK_SECRET}

# GRIT
GRIT_API_URL=${GRIT_API_URL}
GRIT_API_KEY=${GRIT_API_KEY}
MOODLE_IMAGE_TAG=${MOODLE_IMAGE_TAG}
ENV

sudo chmod 600 .env

# Remove old kutt.env if it exists
rm -f kutt.env

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
      shlink:
        condition: service_healthy
      shlink-web:
        condition: service_healthy
      oauth2-proxy:
        condition: service_started
      n8n:
        condition: service_healthy
      moodle:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO /dev/null http://localhost:2019/config/ || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 5

  outline:
    image: docker.getoutline.com/outlinewiki/outline:1.6.1
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

  shlink:
    image: shlinkio/shlink:4
    restart: unless-stopped
    environment:
      - DEFAULT_DOMAIN=go.makenashville.org
      - IS_HTTPS_ENABLED=true
      - DB_DRIVER=postgres
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_NAME=shlink
      - DB_USER=shlink
      - DB_PASSWORD=${SHLINK_DB_PASSWORD}
      - REDIS_SERVERS=redis://redis:6379/2
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/rest/health > /dev/null || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 30s
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  shlink-web:
    image: shlinkio/shlink-web-client:4
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080 > /dev/null || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 5

  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.7.1
    restart: unless-stopped
    environment:
      - OAUTH2_PROXY_PROVIDER=google
      - OAUTH2_PROXY_CLIENT_ID=${OAUTH2_CLIENT_ID}
      - OAUTH2_PROXY_CLIENT_SECRET=${OAUTH2_CLIENT_SECRET}
      - OAUTH2_PROXY_COOKIE_SECRET=${OAUTH2_COOKIE_SECRET}
      - OAUTH2_PROXY_COOKIE_SECURE=true
      - OAUTH2_PROXY_COOKIE_DOMAINS=.makenashville.org
      - OAUTH2_PROXY_WHITELIST_DOMAINS=.makenashville.org
      - OAUTH2_PROXY_EMAIL_DOMAINS=makenashville.org
      - OAUTH2_PROXY_UPSTREAM=static://202
      - OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
      - OAUTH2_PROXY_REVERSE_PROXY=true

  n8n:
    image: n8nio/n8n:stable
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 2g
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - N8N_HOST=automations.makenashville.org
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - WEBHOOK_URL=https://automations.makenashville.org
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_USER_MANAGEMENT_DISABLED=true
      - N8N_DIAGNOSTICS_ENABLED=false
      - GENERIC_TIMEZONE=America/Chicago
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO /dev/null http://localhost:5678/healthz || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 5
      start_period: 30s

  moodle:
    image: ghcr.io/makenashville/moodle:\${MOODLE_IMAGE_TAG:-latest}
    restart: unless-stopped
    environment:
      - MOODLE_DB_HOST=postgres
      - MOODLE_DB_PORT=5432
      - MOODLE_DB_NAME=moodle
      - MOODLE_DB_USER=moodle
      - MOODLE_DB_PASSWORD=${MOODLE_DB_PASSWORD}
      - MOODLE_WWWROOT=https://learn.makenashville.org
      - MOODLE_ADMIN_PASSWORD=${MOODLE_ADMIN_PASSWORD}
      - MOODLE_ADMIN_EMAIL=${MOODLE_ADMIN_EMAIL}
      - MOODLE_REDIS_HOST=redis
      - MOODLE_REDIS_PORT=6379
      - MOODLE_REDIS_DB=3
    volumes:
      - moodle_data:/var/www/moodledata
      - moodle_local:/var/www/html/local
    healthcheck:
      test: ["CMD-SHELL", "curl -sf -H 'X-Forwarded-For: 127.0.0.1' http://localhost/login/index.php || exit 1"]
      interval: 10s
      timeout: 10s
      retries: 10
      start_period: 120s
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  grit-provisioner:
    image: python:3.12-alpine
    restart: unless-stopped
    volumes:
      - ./grit-provisioner:/app:ro
    command: ["python", "/app/server.py"]
    environment:
      - GRIT_API_URL=${GRIT_API_URL}
      - GRIT_API_KEY=${GRIT_API_KEY}
      - WEBHOOK_SECRET=${MOODLE_WEBHOOK_SECRET}
      - COURSE_TOOL_MAP_PATH=/app/course-tool-map.json
      - SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
    healthcheck:
      test: ["CMD-SHELL", "wget -qO /dev/null http://127.0.0.1:8000/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    env_file: .env
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-shlink-db.sql:/docker-entrypoint-initdb.d/init-shlink-db.sql:ro
      - ./init-n8n-db.sql:/docker-entrypoint-initdb.d/init-n8n-db.sql:ro
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
  n8n_data:
  moodle_data:
  moodle_local:
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

# Backup Shlink database
SHLINK_BACKUP_FILE="/tmp/shlink-\${TIMESTAMP}.sql.gz"
docker compose -f /opt/outline/docker-compose.yml exec -T postgres pg_dump -U shlink shlink | gzip > "\${SHLINK_BACKUP_FILE}"
gcloud storage cp "\${SHLINK_BACKUP_FILE}" "\${BUCKET}/shlink-\${TIMESTAMP}.sql.gz"
rm -f "\${SHLINK_BACKUP_FILE}"

# Backup n8n database
N8N_BACKUP_FILE="/tmp/n8n-\${TIMESTAMP}.sql.gz"
docker compose -f /opt/outline/docker-compose.yml exec -T postgres pg_dump -U n8n n8n | gzip > "\${N8N_BACKUP_FILE}"
gcloud storage cp "\${N8N_BACKUP_FILE}" "\${BUCKET}/n8n-\${TIMESTAMP}.sql.gz"
rm -f "\${N8N_BACKUP_FILE}"

# Backup Moodle database
MOODLE_BACKUP_FILE="/tmp/moodle-\${TIMESTAMP}.sql.gz"
docker compose -f /opt/outline/docker-compose.yml exec -T postgres pg_dump -U moodle moodle | gzip > "\${MOODLE_BACKUP_FILE}"
gcloud storage cp "\${MOODLE_BACKUP_FILE}" "\${BUCKET}/moodle-\${TIMESTAMP}.sql.gz"
rm -f "\${MOODLE_BACKUP_FILE}"

# Backup Moodle data volume
MOODLEDATA_BACKUP_FILE="/tmp/moodledata-\${TIMESTAMP}.tar.gz"
docker run --rm -v outline_moodle_data:/data:ro -v /tmp:/backup alpine tar czf "/backup/moodledata-\${TIMESTAMP}.tar.gz" -C /data .
gcloud storage cp "\${MOODLEDATA_BACKUP_FILE}" "\${BUCKET}/moodledata-\${TIMESTAMP}.tar.gz"
rm -f "\${MOODLEDATA_BACKUP_FILE}"

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

echo "[\$(date)] Backup complete: outline, shlink, n8n, and moodle \${TIMESTAMP}"
BACKUPSCRIPT
sudo chmod +x /opt/outline/backup.sh

# Ensure backup cron job is set up (idempotent)
(sudo crontab -l 2>/dev/null | grep -v "backup.sh" || true; echo "0 3 * * * /opt/outline/backup.sh >> /var/log/outline-backup.log 2>&1") | sudo crontab -

# Deploy services (blue-green for changed services, simple restart for excluded)
echo "Deploying services..."
sudo bash /opt/outline/deploy.sh

# Generate Shlink API key if none exist
echo "Checking Shlink API keys..."
sleep 10
EXISTING_KEYS=$(sudo docker compose exec -T shlink shlink api-key:list 2>/dev/null | grep -c "+" || echo "0")
if [[ "$EXISTING_KEYS" -lt 2 ]]; then
    echo ""
    echo "============================================"
    echo "Generating Shlink API key..."
    echo "============================================"
    sudo docker compose exec -T shlink shlink api-key:generate
    echo ""
    echo "Use this API key to connect the Shlink web client at https://links.makenashville.org"
    echo "Server URL: https://go.makenashville.org"
fi

echo "Update complete!"
