# n8n Workflow Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add n8n as a self-hosted workflow automation platform to the Make Nashville Docker Compose stack, with OAuth2-protected UI and public webhook endpoints.

**Architecture:** n8n container with Postgres backend, routed via Caddy at `auto.makenashville.org`. UI protected by the existing shared OAuth2 Proxy (reconfigured for cross-subdomain cookies). Webhooks are public. 2GB memory limit.

**Tech Stack:** n8n (stable), PostgreSQL 16, Caddy 2, OAuth2 Proxy v7.7.1, GitHub Actions, GCP Compute Engine

**Spec:** `docs/superpowers/specs/2026-03-23-n8n-workflow-automation-design.md`

---

### Task 1: Create the n8n database init script

**Files:**
- Create: `deploy/init-n8n-db.sql`

- [ ] **Step 1: Create init-n8n-db.sql**

```sql
CREATE USER n8n WITH PASSWORD 'n8n';
CREATE DATABASE n8n OWNER n8n;
```

This follows the exact pattern of `deploy/init-shlink-db.sql`. The placeholder password is overwritten at deploy time by `startup.sh`.

- [ ] **Step 2: Commit**

```bash
git add deploy/init-n8n-db.sql
git commit -m "feat(n8n): add database init script for fresh deployments"
```

---

### Task 2: Add n8n to docker-compose.yml

**Files:**
- Modify: `docker-compose.yml:81-99` (oauth2-proxy env vars)
- Modify: `docker-compose.yml:101-112` (postgres volumes)
- Modify: `docker-compose.yml:14-22` (caddy depends_on)
- Modify: `docker-compose.yml:123-127` (top-level volumes)
- Add n8n service block after `oauth2-proxy`

- [ ] **Step 1: Update OAuth2 Proxy for cross-subdomain auth**

In `docker-compose.yml`, modify the `oauth2-proxy` service environment block. Remove the hardcoded `OAUTH2_PROXY_REDIRECT_URL` line and add cookie/whitelist domain settings:

Replace lines 86-99:
```yaml
    environment:
      - OAUTH2_PROXY_PROVIDER=google
      - OAUTH2_PROXY_CLIENT_ID=${OAUTH2_PROXY_CLIENT_ID:-placeholder}
      - OAUTH2_PROXY_CLIENT_SECRET=${OAUTH2_PROXY_CLIENT_SECRET:-placeholder}
      - OAUTH2_PROXY_COOKIE_SECRET=${OAUTH2_PROXY_COOKIE_SECRET:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
      - OAUTH2_PROXY_COOKIE_SECURE=true
      - OAUTH2_PROXY_COOKIE_DOMAINS=.makenashville.org
      - OAUTH2_PROXY_WHITELIST_DOMAINS=.makenashville.org
      - OAUTH2_PROXY_EMAIL_DOMAINS=makenashville.org
      - OAUTH2_PROXY_GOOGLE_GROUPS=${OAUTH2_PROXY_GOOGLE_GROUPS:-}
      - OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL=${OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL:-}
      - OAUTH2_PROXY_GOOGLE_SERVICE_ACCOUNT_JSON=/etc/oauth2-proxy/google-sa-key.json
      - OAUTH2_PROXY_UPSTREAM=static://202
      - OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
      - OAUTH2_PROXY_REVERSE_PROXY=true
```

Key change: removed `OAUTH2_PROXY_REDIRECT_URL` (proxy auto-detects from request), added `COOKIE_DOMAINS` and `WHITELIST_DOMAINS` for `.makenashville.org`.

- [ ] **Step 2: Add init-n8n-db.sql mount to postgres**

In the `postgres` service, add the n8n init script volume mount after the existing shlink one at line 107:

```yaml
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./deploy/init-shlink-db.sql:/docker-entrypoint-initdb.d/init-shlink-db.sql:ro
      - ./deploy/init-n8n-db.sql:/docker-entrypoint-initdb.d/init-n8n-db.sql:ro
```

- [ ] **Step 3: Add n8n service**

Add the n8n service block after the `oauth2-proxy` service (before `postgres`):

```yaml
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
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD:-n8n}
      - N8N_HOST=auto.makenashville.org
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - WEBHOOK_URL=https://auto.makenashville.org
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY:-placeholder-change-me}
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
```

- [ ] **Step 4: Add n8n to Caddy depends_on**

Update the `caddy` service `depends_on` block (lines 14-22) to include n8n:

```yaml
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
```

- [ ] **Step 5: Add n8n_data to top-level volumes**

Update the `volumes:` section at the bottom (lines 123-127):

```yaml
volumes:
  postgres_data:
  caddy_data:
  caddy_config:
  n8n_data:
```

- [ ] **Step 6: Verify docker-compose syntax**

Run: `docker compose -f docker-compose.yml config --quiet`
Expected: no output (valid syntax)

- [ ] **Step 7: Commit**

```bash
git add docker-compose.yml
git commit -m "feat(n8n): add n8n service to docker-compose with cross-subdomain OAuth2"
```

---

### Task 3: Add n8n route to Caddyfile

**Files:**
- Modify: `Caddyfile` (add new site block after line 47)

- [ ] **Step 1: Add auto.makenashville.org site block**

Append after the `to.makenashville.org, go.makenashville.org` block (after line 47):

```caddyfile

auto.makenashville.org {
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
				redir * https://auto.makenashville.org/oauth2/start?rd={scheme}://{host}{uri}
			}
		}
		reverse_proxy n8n:5678
	}
}
```

- [ ] **Step 2: Commit**

```bash
git add Caddyfile
git commit -m "feat(n8n): add Caddy routing for auto.makenashville.org with webhook bypass"
```

---

### Task 4: Update .env.example and .env.production.example

**Files:**
- Modify: `.env.example` (add n8n vars after line 68)
- Modify: `.env.production.example` (add n8n vars after line 54)

- [ ] **Step 1: Add n8n section to .env.example**

Append after line 68 (after the Authentication section):

```
# ===================
# n8n
# ===================
N8N_DB_PASSWORD=n8n
N8N_ENCRYPTION_KEY=generate-a-hex-string
```

- [ ] **Step 2: Add n8n section to .env.production.example**

Append after line 54 (after the Secrets section):

```

# ===================
# Shlink
# ===================
SHLINK_DB_PASSWORD=

# ===================
# OAuth2 Proxy
# ===================
OAUTH2_PROXY_CLIENT_ID=
OAUTH2_PROXY_CLIENT_SECRET=
OAUTH2_PROXY_COOKIE_SECRET=
OAUTH2_PROXY_GOOGLE_GROUPS=
OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL=

# ===================
# n8n
# ===================
N8N_DB_PASSWORD=
N8N_ENCRYPTION_KEY=
```

Note: The Shlink and OAuth2 sections are missing from `.env.production.example` (pre-existing gap). Adding them here alongside n8n for completeness. If they already exist when this task runs, just add the n8n section.

- [ ] **Step 3: Commit**

```bash
git add .env.example .env.production.example
git commit -m "feat(n8n): add n8n env vars to example files"
```

---

### Task 5: Update deploy/update-server.sh

**Files:**
- Modify: `deploy/update-server.sh:1-29` (metadata fetching)
- Modify: `deploy/update-server.sh:31-38` (database creation)
- Modify: `deploy/update-server.sh:43-91` (Caddyfile heredoc)
- Modify: `deploy/update-server.sh:94-135` (.env heredoc)
- Modify: `deploy/update-server.sh:143-270` (docker-compose heredoc)
- Modify: `deploy/update-server.sh:273-313` (backup script heredoc)

- [ ] **Step 1: Add n8n metadata fetching**

After line 29 (`OAUTH2_GOOGLE_ADMIN_EMAIL=$(get_metadata "oauth2-google-admin-email")`), add:

```bash
N8N_DB_PASSWORD=$(get_metadata "n8n-db-password")
N8N_ENCRYPTION_KEY=$(get_metadata "n8n-encryption-key")
```

- [ ] **Step 2: Add n8n database creation block**

After the Shlink database block (after line 38), add:

```bash

# Create n8n database if it doesn't exist
echo "Ensuring n8n database exists..."
sudo docker compose exec -T postgres psql -U outline -tc "SELECT 1 FROM pg_roles WHERE rolname='n8n'" | grep -q 1 || \
    sudo docker compose exec -T postgres psql -U outline -c "CREATE USER n8n WITH PASSWORD '${N8N_DB_PASSWORD}';"
sudo docker compose exec -T postgres psql -U outline -c "ALTER USER n8n WITH PASSWORD '${N8N_DB_PASSWORD}';"
sudo docker compose exec -T postgres psql -U outline -tc "SELECT 1 FROM pg_database WHERE datname='n8n'" | grep -q 1 || \
    sudo docker compose exec -T postgres psql -U outline -c "CREATE DATABASE n8n OWNER n8n;"
```

- [ ] **Step 3: Update Caddyfile heredoc**

In the Caddyfile heredoc (lines 43-91), make two changes:

(a) Append the `auto.makenashville.org` site block before the closing `CADDY` delimiter (after the `to.makenashville.org` block):

```caddyfile

auto.makenashville.org {
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
				redir * https://auto.makenashville.org/oauth2/start?rd={scheme}://{host}{uri}
			}
		}
		reverse_proxy n8n:5678
	}
}
```

- [ ] **Step 4: Update .env heredoc**

In the .env heredoc (lines 94-135), add after the Shlink line (line 134):

```bash

# n8n
N8N_DB_PASSWORD=${N8N_DB_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
```

- [ ] **Step 5: Update docker-compose heredoc**

In the docker-compose heredoc (lines 143-270), make these changes:

(a) In the `oauth2-proxy` service block, remove the `OAUTH2_PROXY_REDIRECT_URL` line and add:
```yaml
      - OAUTH2_PROXY_COOKIE_DOMAINS=.makenashville.org
      - OAUTH2_PROXY_WHITELIST_DOMAINS=.makenashville.org
```

(b) Add the n8n service block after `oauth2-proxy` (before `postgres`):
```yaml

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
      - N8N_HOST=auto.makenashville.org
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - WEBHOOK_URL=https://auto.makenashville.org
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
```

(c) Add `n8n` to Caddy's `depends_on`:
```yaml
      n8n:
        condition: service_healthy
```

(d) Add `init-n8n-db.sql` mount to postgres volumes:
```yaml
      - ./init-n8n-db.sql:/docker-entrypoint-initdb.d/init-n8n-db.sql:ro
```

(e) Add `n8n_data:` to the top-level `volumes:` section.

- [ ] **Step 6: Update backup script heredoc**

In the backup heredoc (lines 273-313), add n8n backup after the Shlink backup block (after line 299):

```bash

# Backup n8n database
N8N_BACKUP_FILE="/tmp/n8n-\${TIMESTAMP}.sql.gz"
docker compose -f /opt/outline/docker-compose.yml exec -T postgres pg_dump -U n8n n8n | gzip > "\${N8N_BACKUP_FILE}"
gcloud storage cp "\${N8N_BACKUP_FILE}" "\${BUCKET}/n8n-\${TIMESTAMP}.sql.gz"
rm -f "\${N8N_BACKUP_FILE}"
```

Also update the echo line at line 312 — replace `echo "[\$(date)] Backup complete: outline and shlink \${TIMESTAMP}"` with:
```bash
echo "[\$(date)] Backup complete: outline, shlink, and n8n \${TIMESTAMP}"
```

- [ ] **Step 7: Commit**

```bash
git add deploy/update-server.sh
git commit -m "feat(n8n): update deploy script with n8n database, compose, caddy, and backup"
```

---

### Task 6: Update deploy/startup.sh

**Files:**
- Modify: `deploy/startup.sh:52-67` (metadata fetching)
- Modify: `deploy/startup.sh:78-205` (docker-compose heredoc)
- Modify: `deploy/startup.sh:416-421` (shlink init SQL heredoc area — add n8n init)
- Modify: `deploy/startup.sh:425-473` (Caddyfile heredoc)
- Modify: `deploy/startup.sh:477-517` (.env heredoc)
- Add backup script heredoc (startup.sh currently has no backup script — it's written by update-server.sh, but startup.sh should also set it up for first boot)

- [ ] **Step 1: Add n8n metadata fetching**

After line 62 (`SHLINK_DB_PASSWORD=$(get_metadata "shlink-db-password")`), add:

```bash
N8N_DB_PASSWORD=$(get_metadata "n8n-db-password")
N8N_ENCRYPTION_KEY=$(get_metadata "n8n-encryption-key")
```

- [ ] **Step 2: Update docker-compose heredoc**

Same changes as Task 5 Step 5:
(a) Remove `OAUTH2_PROXY_REDIRECT_URL`, add `COOKIE_DOMAINS` and `WHITELIST_DOMAINS`
(b) Add n8n service block
(c) Add n8n to Caddy depends_on
(d) Add init-n8n-db.sql mount to postgres
(e) Add `n8n_data:` to volumes

- [ ] **Step 3: Add n8n database init script heredoc**

After the Shlink init script heredoc (after line 421), add:

```bash

# Create n8n database init script with production password
log "Creating n8n database init script..."
cat > init-n8n-db.sql <<N8NSQL
CREATE USER n8n WITH PASSWORD '${N8N_DB_PASSWORD}';
CREATE DATABASE n8n OWNER n8n;
N8NSQL
```

- [ ] **Step 4: Update Caddyfile heredoc**

Same as Task 5 Step 3 — add `auto.makenashville.org` block before the closing `CADDY` delimiter.

- [ ] **Step 5: Update .env heredoc**

Same as Task 5 Step 4 — add n8n vars at the end before `ENV` delimiter.

- [ ] **Step 6: Add backup script heredoc**

`startup.sh` currently has no backup script setup. Add a backup script heredoc after the `.env` heredoc (after the `chmod 600 .env` line) so first-boot VMs also get backup configured. This matches what `update-server.sh` does at lines 273-317:

```bash

# Write backup script
log "Creating backup script..."
cat > /opt/outline/backup.sh <<BACKUPSCRIPT
#!/bin/bash
set -euo pipefail

BUCKET="gs://make-nashville-wiki-uploads/backups"
TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="/tmp/outline-\${TIMESTAMP}.sql.gz"
RETAIN_DAYS=14
WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

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

echo "[\$(date)] Backup complete: outline, shlink, and n8n \${TIMESTAMP}"
BACKUPSCRIPT
chmod +x /opt/outline/backup.sh

# Ensure backup cron job is set up
(crontab -l 2>/dev/null | grep -v "backup.sh" || true; echo "0 3 * * * /opt/outline/backup.sh >> /var/log/outline-backup.log 2>&1") | crontab -
```

- [ ] **Step 7: Add n8n completion log message**

Add a new log line after line 542 (`log "Shlink web client at https://links.makenashville.org"`):

```bash
log "n8n workflow automation at https://auto.makenashville.org"
```

- [ ] **Step 8: Commit**

```bash
git add deploy/startup.sh
git commit -m "feat(n8n): update startup script with n8n provisioning"
```

---

### Task 7: Update GitHub Actions deploy workflow

**Files:**
- Modify: `.github/workflows/deploy.yml:42-62` (metadata step)
- Modify: `.github/workflows/deploy.yml:64-73` (upload files step)

- [ ] **Step 1: Add n8n secrets to instance metadata**

In the `Update instance metadata` step (lines 43-62), add before the closing line:

```yaml
          n8n-db-password="${{ secrets.N8N_DB_PASSWORD }}",\
          n8n-encryption-key="${{ secrets.N8N_ENCRYPTION_KEY }}"
```

Note: The last metadata entry should NOT have a trailing comma+backslash. Move the backslash from the current last line (`oauth2-google-admin-email`) and ensure the new last line has no trailing backslash.

- [ ] **Step 2: Add SCP step for init-n8n-db.sql**

In the `Upload files to server` step (after line 70), add:

```yaml
          gcloud compute scp deploy/init-n8n-db.sql "$INSTANCE_NAME:~/init-n8n-db.sql" --zone="$ZONE"
          gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/init-n8n-db.sql /opt/outline/init-n8n-db.sql && sudo chmod 644 /opt/outline/init-n8n-db.sql'
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(n8n): add n8n secrets and init script to deploy workflow"
```

---

### Task 8: Update README

**Files:**
- Modify: `README.md` (add n8n to services list, mention auto.makenashville.org, document new secrets)

- [ ] **Step 1: Read current README**

Read `README.md` to understand the current structure and where to add n8n documentation.

- [ ] **Step 2: Add n8n to the README**

Add n8n to:
- The services list/overview section
- The environment variables / secrets section (document `N8N_DB_PASSWORD` and `N8N_ENCRYPTION_KEY`)
- The URLs/endpoints section (mention `auto.makenashville.org`)
- Any architecture diagram if one exists

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add n8n workflow automation to README"
```

---

### Task 9: Local dev setup (optional)

**Files:**
- Modify: `Caddyfile.local` (add n8n route for localhost)
- Modify: `docker-compose.local.yml` (add n8n local overrides if needed)

- [ ] **Step 1: Evaluate if local dev changes are needed**

The main `docker-compose.yml` already contains the n8n service, which works for local dev. `Caddyfile.local` currently only has a `localhost` block for Outline. For local dev, n8n would be accessible directly at `http://localhost:5678` since docker-compose doesn't expose the port externally (no `ports` mapping).

If port-based local access is desired, add to `docker-compose.local.yml`:

```yaml
  n8n:
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=localhost
      - N8N_PROTOCOL=http
      - WEBHOOK_URL=http://localhost:5678
      - N8N_USER_MANAGEMENT_DISABLED=true
```

- [ ] **Step 2: Commit (if changes made)**

```bash
git add docker-compose.local.yml Caddyfile.local
git commit -m "feat(n8n): add local dev configuration"
```

---

### Task 10: Final verification

- [ ] **Step 1: Verify all files are consistent**

Run: `git diff --stat main`
Expected: Changes in all files listed in the spec's "Files Changed" section.

- [ ] **Step 2: Verify docker-compose syntax**

Run: `docker compose -f docker-compose.yml config --quiet`
Expected: no output (valid syntax)

- [ ] **Step 3: Review the full diff**

Run: `git log --oneline main..HEAD`
Verify all commits are present and well-ordered.
