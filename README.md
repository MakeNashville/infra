# Make Nashville Infrastructure

Docker Compose setup for [Outline](https://www.getoutline.com/) wiki, [n8n](https://n8n.io/) workflow automation, and supporting services, with local development and GCP deployment.

## Overview

| Service | Local | Production |
|---------|-------|------------|
| **Outline** | `outline:1.6.1` | `outline:1.6.1` |
| **Caddy** | `caddy:2-alpine` (local TLS) | `caddy:2-alpine` (Let's Encrypt) |
| **PostgreSQL** | `postgres:16-alpine` | `postgres:16-alpine` |
| **Redis** | `redis:7-alpine` | `redis:7-alpine` |
| **Storage** | MinIO (local) | Google Cloud Storage |
| **n8n** | `n8nio/n8n:latest` | `n8nio/n8n:latest` |

## URLs

| Service | URL | Notes |
|---------|-----|-------|
| Outline wiki | `https://wiki.makenashville.org` | OAuth2 protected |
| n8n workflow editor | `https://automations.makenashville.org` | OAuth2 protected |
| n8n webhooks | `https://automations.makenashville.org/webhook/*` | Public |

## Local Development

1. Install mkcert and generate local certificates:

   **macOS:**
   ```bash
   brew install mkcert
   mkcert -install
   mkcert localhost
   ```

   **Linux (Debian/Ubuntu):**
   ```bash
   sudo apt install libnss3-tools mkcert
   mkcert -install
   mkcert localhost
   ```

2. Copy environment file:
   ```bash
   cp .env.example .env
   ```

3. Generate secrets:
   ```bash
   openssl rand -hex 32  # Run twice — paste into SECRET_KEY and UTILS_SECRET in .env
   ```

4. Configure Slack authentication in `.env`:
   - Create a Slack app at https://api.slack.com/apps
   - Add redirect URL: `https://localhost/auth/slack.callback`
   - Add User Token Scopes: `identity.avatar`, `identity.basic`, `identity.email`, `identity.team`
   - Copy Client ID and Client Secret to `.env`

5. Start services:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
   ```

6. Create MinIO bucket:
   ```bash
   docker compose exec minio mc alias set local http://localhost:9000 minioadmin minioadmin
   docker compose exec minio mc mb local/outline
   ```

7. Access at https://localhost

## GCP Deployment

Production deploys happen automatically via GitHub Actions on every push to `main`. The workflow authenticates with GCP via Workload Identity Federation, updates instance metadata with secrets, uploads deploy files, and runs `deploy/update-server.sh` on the VM.

### First-time infrastructure setup

This only needs to be done once when setting up a new environment.

1. Set up Workload Identity Federation for GitHub Actions:
   ```bash
   ./deploy/setup-wif.sh
   ```
   This creates the service account, WIF pool, and OIDC provider, then prints the secret values to add to GitHub.

2. Add the following secrets to GitHub (Settings → Secrets and variables → Actions):

   | Secret | Value |
   |--------|-------|
   | `GCP_WORKLOAD_IDENTITY_PROVIDER` | WIF provider resource name (output by `setup-wif.sh`) |
   | `GCP_SERVICE_ACCOUNT` | Deploy service account email (output by `setup-wif.sh`) |
   | `GCP_PROJECT_ID` | GCP project ID (output by `setup-wif.sh`) |
   | `GOOGLE_SA_KEY_JSON` | Service account key JSON for GCS access from the VM |
   | `DOMAIN` | Your wiki domain |
   | `GCS_BUCKET` | GCS bucket name |
   | `GCS_ACCESS_KEY` | GCS HMAC access key |
   | `GCS_SECRET_KEY` | GCS HMAC secret |
   | `SLACK_CLIENT_ID` | Slack app client ID |
   | `SLACK_CLIENT_SECRET` | Slack app client secret |
   | `SECRET_KEY` | Outline secret key (32-byte hex) |
   | `UTILS_SECRET` | Outline utils secret (32-byte hex) |
   | `POSTGRES_PASSWORD` | Database password |
   | `SLACK_WEBHOOK_URL` | Slack incoming webhook URL (optional — enables deploy and backup notifications) |
   | `SHLINK_DB_PASSWORD` | Shlink database password |
   | `OAUTH2_PROXY_CLIENT_ID` | OAuth2 Proxy Google client ID |
   | `OAUTH2_PROXY_CLIENT_SECRET` | OAuth2 Proxy Google client secret |
   | `OAUTH2_PROXY_COOKIE_SECRET` | OAuth2 Proxy cookie secret |
   | `OAUTH2_PROXY_GOOGLE_GROUPS` | Allowed Google group for access |
   | `OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL` | Google Workspace admin email for group lookup |
   | `N8N_DB_PASSWORD` | n8n database password |
   | `N8N_ENCRYPTION_KEY` | n8n credentials encryption key (32-byte hex) |

   Optionally add these as Actions Variables (non-secret) to override defaults:

   | Variable | Default |
   |----------|---------|
   | `REGION` | `us-central1` |
   | `ZONE` | `us-central1-a` |
   | `INSTANCE_NAME` | `make-nashville-wiki` |

3. Push to `main` to trigger the first deploy. The script will reserve a static IP, create the VM, configure GCS CORS, and start all services.

4. Point your DNS A record to the printed static IP, then visit `https://your-domain`.

### Manual deploy

If you need to deploy outside of GitHub Actions (e.g., for debugging):

```bash
cp .env.production.example .env.production
# Edit .env.production with your values
./deploy/gcloud-setup.sh
```

## Upgrading Outline

The Outline image is pinned to avoid breaking the S3Storage.js patch (see Architecture below).

To upgrade:

1. Check the [Outline changelog](https://github.com/outline/outline/releases) for breaking changes.

2. Update the image tag in all three locations:
   - `docker-compose.yml`
   - `deploy/startup.sh` (in the docker-compose.yml heredoc)
   - `deploy/update-server.sh` (in the docker-compose.yml heredoc)

3. Extract and patch the new `S3Storage.js` from the new image:
   ```bash
   docker run --rm docker.getoutline.com/outlinewiki/outline:NEW_VERSION \
     cat /opt/outline/build/server/storage/files/S3Storage.js > deploy/S3Storage.js
   ```
   Then re-apply the two patches described below.

4. Test locally before deploying:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
   ```

## Architecture

### S3Storage.js patch

Outline's built-in S3 storage doesn't work with Google Cloud Storage out of the box. Two issues affect GCS with uniform bucket-level access:

1. **Missing `Content-Disposition` policy condition** — GCS presigned POST requires a policy condition for every form field. Outline sends `Content-Disposition` but the original code has no matching condition.

2. **ACL field rejected by GCS** — Outline includes `acl: "private"` in presigned POST form fields. GCS rejects any ACL field when uniform bucket-level access is enabled.

`deploy/S3Storage.js` is a patched build artifact that fixes both issues. It is mounted as a read-only volume over the file inside the container:

```yaml
volumes:
  - ./deploy/S3Storage.js:/opt/outline/build/server/storage/files/S3Storage.js:ro
```

Because this patches a compiled build artifact, the patch must be regenerated whenever the Outline image version changes.

## Contributing

Make Nashville wiki infrastructure is maintained by Make Nashville volunteers.

### Workflow

1. Fork the repo and create a branch from `main`.
2. Make your changes and test locally (see Local Development above).
3. Open a pull request against `main`. Include a description of what changed and why.
4. Once merged, GitHub Actions will automatically deploy to production.

### What to contribute

- Bug fixes and reliability improvements
- Documentation improvements
- Security patches
- Outline version upgrades (follow the Upgrading Outline steps above)

### What requires extra care

- Changes to `deploy/gcloud-setup.sh`, `deploy/update-server.sh`, or `deploy/startup.sh` affect production infrastructure. Test with a separate GCP instance if possible.
- Changes to `deploy/S3Storage.js` must be validated against live file uploads — the GCS presigned POST flow is sensitive to field ordering and conditions.
- Never commit `.env`, `.env.production`, or any file containing secrets.

### Getting access

Contact a Make Nashville board member to get added to the GitHub org and to receive credentials for local Slack OAuth testing.
