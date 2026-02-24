# Outline Docker Compose for Make Nashville

Docker Compose setup for [Outline](https://www.getoutline.com/) wiki, supporting local development and GCP deployment.

## Overview

| Service | Local | Production |
|---------|-------|------------|
| **Outline** | `outline:1.4.0` | `outline:1.4.0` |
| **Caddy** | `caddy:2-alpine` (local TLS) | `caddy:2-alpine` (Let's Encrypt) |
| **PostgreSQL** | `postgres:16-alpine` | `postgres:16-alpine` |
| **Redis** | `redis:7-alpine` | `redis:7-alpine` |
| **Storage** | MinIO (local) | Google Cloud Storage |

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

Production deploys happen automatically via GitHub Actions on every push to `main`. The workflow authenticates with GCP, reconstructs `.env.production` from GitHub secrets, and runs `deploy/gcloud-setup.sh`.

### First-time infrastructure setup

This only needs to be done once when setting up a new environment.

1. Create the GCP service account for GitHub Actions:
   ```bash
   gcloud iam service-accounts create github-deploy \
     --display-name="GitHub Actions deploy" \
     --project=YOUR_PROJECT_ID

   gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
     --member="serviceAccount:github-deploy@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
     --role="roles/compute.instanceAdmin.v1"

   gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
     --member="serviceAccount:github-deploy@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
     --role="roles/storage.admin"

   gcloud iam service-accounts add-iam-policy-binding \
     YOUR_PROJECT_NUMBER-compute@developer.gserviceaccount.com \
     --member="serviceAccount:github-deploy@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
     --role="roles/iam.serviceAccountUser"

   gcloud iam service-accounts keys create github-deploy-key.json \
     --iam-account=github-deploy@YOUR_PROJECT_ID.iam.gserviceaccount.com

   # Base64-encode the key for GitHub secrets
   cat github-deploy-key.json | base64 | tr -d '\n'
   rm github-deploy-key.json
   ```

2. Add the following secrets to GitHub (Settings → Secrets and variables → Actions):

   | Secret | Value |
   |--------|-------|
   | `GCP_SA_KEY` | Base64-encoded service account key JSON |
   | `PROJECT_ID` | GCP project ID |
   | `DOMAIN` | Your wiki domain |
   | `GCS_BUCKET` | GCS bucket name |
   | `GCS_ACCESS_KEY` | GCS HMAC access key |
   | `GCS_SECRET_KEY` | GCS HMAC secret |
   | `SLACK_CLIENT_ID` | Slack app client ID |
   | `SLACK_CLIENT_SECRET` | Slack app client secret |
   | `SECRET_KEY` | Outline secret key (32-byte hex) |
   | `UTILS_SECRET` | Outline utils secret (32-byte hex) |
   | `POSTGRES_PASSWORD` | Database password |

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

2. Update the image tag in all four locations:
   - `docker-compose.yml`
   - `deploy/startup.sh` (in the docker-compose.yml heredoc)
   - `deploy/gcloud-setup.sh` (in the docker-compose.yml heredoc, update path)

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

- Changes to `deploy/gcloud-setup.sh` or `deploy/startup.sh` affect production infrastructure. Test with a separate GCP instance if possible.
- Changes to `deploy/S3Storage.js` must be validated against live file uploads — the GCS presigned POST flow is sensitive to field ordering and conditions.
- Never commit `.env`, `.env.production`, or any file containing secrets.

### Getting access

Contact a Make Nashville board member to get added to the GitHub org and to receive credentials for local Slack OAuth testing.
