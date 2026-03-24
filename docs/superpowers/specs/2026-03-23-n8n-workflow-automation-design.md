# n8n Workflow Automation — Design Spec

## Overview

Add n8n as a self-hosted workflow automation platform to the existing Docker Compose stack. The UI is protected behind the shared OAuth2 Proxy (Google Workspace auth), routed via Caddy at `auto.makenashville.org`. Webhook endpoints are public so external services can trigger workflows. n8n uses a dedicated database on the shared Postgres instance and has a container memory limit to protect other services on the VM.

## Goals

- Visual, maintainable workflow automation replacing one-off scripts
- Automate member onboarding flows (Slack invite, wiki access, orientation scheduling)
- Sync data between services (Outline, Shlink, Slack, calendar)
- Webhook-driven notifications and alerts
- Google Workspace authentication (same as Shlink admin UI)
- Credential encryption at rest via `N8N_ENCRYPTION_KEY`
- Database backed up alongside existing services

## Architecture

```
Internet → Caddy (TLS, ports 80/443)
              ├── wiki.makenashville.org   → Outline:3000
              ├── links.makenashville.org  → forward_auth(oauth2-proxy) → shlink-web:8080
              ├── to/go.makenashville.org  → Shlink:8080
              └── auto.makenashville.org
                    ├── /oauth2/*          → oauth2-proxy:4180
                    ├── /webhook/*         → n8n:5678 (public, no auth)
                    ├── /webhook-test/*    → n8n:5678 (public, no auth)
                    └── /* (UI + API)      → forward_auth(oauth2-proxy) → n8n:5678
```

### New Container

- **n8n** (`n8nio/n8n:stable`) — workflow automation, port 5678, memory limit 2GB

### Shared Infrastructure

- **Postgres** — new `n8n` database and `n8n` user on existing instance
- **Redis** — not required by n8n (n8n uses its own internal queue by default)
- **OAuth2 Proxy** — existing instance, reused via Caddy `forward_auth`

## Auth Flow

### Webhook Endpoints (No Auth)

Requests to `auto.makenashville.org/webhook/*` and `/webhook-test/*` are proxied directly to n8n with no OAuth check. External services (Slack, GitHub, etc.) hit these endpoints to trigger workflows. n8n handles its own webhook authentication via per-workflow tokens, headers, or basic auth configured within each workflow.

### UI Access (Google Workspace Auth)

1. User visits `auto.makenashville.org/` (n8n editor UI)
2. Caddy's `forward_auth` sends subrequest to oauth2-proxy
3. oauth2-proxy sees no valid session cookie → redirects to Google OIDC login
4. User authenticates with Make Nashville Google Workspace account
5. oauth2-proxy checks domain (`makenashville.org`) and optional Google Group membership
6. If authorized → session cookie set, request proxied to n8n
7. Subsequent requests pass through automatically (cookie is valid)

## Caddy Configuration

New site block for `auto.makenashville.org`:

```caddyfile
auto.makenashville.org {
    header {
        X-Frame-Options SAMEORIGIN
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }

    # OAuth callback/sign-in routes
    handle /oauth2/* {
        reverse_proxy oauth2-proxy:4180
    }

    # Public webhook endpoints — no auth, external services call these
    @webhooks {
        path /webhook/* /webhook-test/*
    }
    handle @webhooks {
        reverse_proxy n8n:5678
    }

    # Everything else (UI, API, REST endpoints) — protected
    handle {
        forward_auth oauth2-proxy:4180 {
            uri /oauth2/auth
            header_up X-Forwarded-Host {host}
            copy_headers X-Auth-Request-User X-Auth-Request-Email
        }
        reverse_proxy n8n:5678
    }
}
```

## Docker Compose

n8n service definition:

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
    - WEBHOOK_URL=https://auto.makenashville.org/
    - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
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
```

Named volume `n8n_data` persists encryption key files, custom nodes, and runtime config.

## Database & Storage

### Postgres

- New database `n8n` with dedicated user `n8n` and its own password
- Init script `deploy/init-n8n-db.sql` mounted at `/docker-entrypoint-initdb.d/` for fresh deployments
- `update-server.sh` gets an idempotent `ALTER USER / CREATE DATABASE` block for n8n, following the Shlink pattern

### init-n8n-db.sql

```sql
-- Create n8n user and database (runs on fresh Postgres init only)
CREATE USER n8n WITH PASSWORD :'n8n_password';
CREATE DATABASE n8n OWNER n8n;
```

Password injected via environment variable, same mechanism as `init-shlink-db.sql`.

### No Object Storage

n8n stores workflows and credentials in Postgres. Binary data (uploaded files in workflows) is stored in the `/home/node/.n8n` volume. No GCS/S3 integration needed.

## Backup

Add `n8n` database to the existing backup cron. Same pattern as Outline and Shlink:

- `pg_dump` the `n8n` database with gzip compression
- Upload to `gs://make-nashville-wiki-uploads/backups/` as `n8n-YYYYMMDD-HHMMSS.sql.gz`
- Same 14-day retention policy
- Same Slack failure notification

This covers workflows, credentials (encrypted in DB), and execution history.

## n8n Configuration

Key environment variables:

| Variable | Value |
|---|---|
| `DB_TYPE` | `postgresdb` |
| `DB_POSTGRESDB_HOST` | `postgres` |
| `DB_POSTGRESDB_PORT` | `5432` |
| `DB_POSTGRESDB_DATABASE` | `n8n` |
| `DB_POSTGRESDB_USER` | `n8n` |
| `DB_POSTGRESDB_PASSWORD` | (from GitHub Secret) |
| `N8N_HOST` | `auto.makenashville.org` |
| `N8N_PROTOCOL` | `https` |
| `N8N_PORT` | `5678` |
| `WEBHOOK_URL` | `https://auto.makenashville.org/` |
| `N8N_ENCRYPTION_KEY` | (from GitHub Secret) |
| `GENERIC_TIMEZONE` | `America/Chicago` |

## Container Dependencies

```
n8n → postgres (healthy)
oauth2-proxy → (none — standalone, already running)
caddy → outline (healthy), oauth2-proxy (healthy), shlink (healthy), shlink-web (healthy), n8n (healthy)
```

## Resource Limits

- Memory limit: `2g` on the n8n container
- Monitor via `docker stats` — if n8n consistently hits the limit, increase or optimize active workflows
- No CPU limit initially (let it burst as needed)

## Files Changed

### Modified

- `docker-compose.yml` — add n8n container; add `n8n_data` volume; add `init-n8n-db.sql` mount on postgres; update Caddy `depends_on`
- `docker-compose.local.yml` — add n8n for local dev (if applicable)
- `Caddyfile` — add `auto.makenashville.org` site block
- `Caddyfile.local` — add local n8n route (if applicable)
- `.env.example` — add `N8N_DB_PASSWORD`, `N8N_ENCRYPTION_KEY`
- `.env.production.example` — add n8n production variables
- `deploy/startup.sh` — include n8n in docker-compose heredoc, backup script generation
- `deploy/update-server.sh` — add idempotent n8n database/user creation, include n8n in compose
- `.github/workflows/deploy.yml` — add `N8N_DB_PASSWORD` and `N8N_ENCRYPTION_KEY` to instance metadata

### New

- `deploy/init-n8n-db.sql` — creates `n8n` database and user (fresh deployments only)

## New GitHub Secrets

- `N8N_DB_PASSWORD` — Postgres password for the n8n user
- `N8N_ENCRYPTION_KEY` — Encrypts credentials stored in n8n's database (generate with `openssl rand -hex 32`)

## Manual Prerequisites (Before Deploy)

1. Create DNS A record: `auto.makenashville.org` → VM's external IP
2. Add `N8N_DB_PASSWORD` and `N8N_ENCRYPTION_KEY` to GitHub repository secrets
3. No new OAuth app needed — reuses the existing OAuth2 Proxy instance and Google OAuth app
