# n8n Workflow Automation — Design Spec

## Overview

Add n8n as a self-hosted workflow automation platform to the existing Docker Compose stack. The UI is protected behind the shared OAuth2 Proxy (Google Workspace auth), routed via Caddy at `automations.makenashville.org`. Webhook endpoints are public so external services can trigger workflows. n8n uses a dedicated database on the shared Postgres instance and has a container memory limit to protect other services on the VM.

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
              └── automations.makenashville.org
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
- **OAuth2 Proxy** — existing instance, reconfigured with cross-subdomain cookies (see Auth Flow)

## Auth Flow

### Webhook Endpoints (No Auth)

Requests to `automations.makenashville.org/webhook/*` and `/webhook-test/*` are proxied directly to n8n with no OAuth check. External services (Slack, GitHub, etc.) hit these endpoints to trigger workflows. n8n handles its own webhook authentication via per-workflow tokens, headers, or basic auth configured within each workflow.

### UI Access (Google Workspace Auth)

1. User visits `automations.makenashville.org/` (n8n editor UI)
2. Caddy's `forward_auth` sends subrequest to oauth2-proxy
3. oauth2-proxy sees no valid session cookie → redirects to Google OIDC login
4. User authenticates with Make Nashville Google Workspace account
5. oauth2-proxy checks domain (`makenashville.org`) and optional Google Group membership
6. If authorized → session cookie set on `.makenashville.org`, request proxied to n8n
7. Subsequent requests pass through automatically (cookie is valid across subdomains)

### OAuth2 Proxy Cross-Subdomain Changes

The existing OAuth2 Proxy has `OAUTH2_PROXY_REDIRECT_URL` hardcoded to `https://links.makenashville.org/oauth2/callback`. To share a single proxy across both `links.` and `auto.`, the following changes are needed:

| Variable | Current Value | New Value |
|---|---|---|
| `OAUTH2_PROXY_REDIRECT_URL` | `https://links.makenashville.org/oauth2/callback` | **Remove** (let proxy auto-detect from request) |
| `OAUTH2_PROXY_COOKIE_DOMAINS` | (not set) | `.makenashville.org` |
| `OAUTH2_PROXY_WHITELIST_DOMAINS` | (not set) | `.makenashville.org` |

Additionally, the Google OAuth app in Cloud Console must add `https://automations.makenashville.org/oauth2/callback` as an authorized redirect URI (alongside the existing `links.` one).

### n8n Built-in Auth

n8n has its own user management with an owner account created on first launch. Since the UI is behind OAuth2 Proxy, we set `N8N_USER_MANAGEMENT_DISABLED=true` to skip n8n's login screen entirely. This avoids a double-login experience — OAuth2 Proxy is the sole authentication gate.

## Caddy Configuration

New site block for `automations.makenashville.org`:

```caddyfile
automations.makenashville.org {
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
```

The `n8n_data` volume must be declared in the top-level `volumes:` section alongside `postgres_data`, `caddy_data`, and `caddy_config`:

```yaml
volumes:
  postgres_data:
  caddy_data:
  caddy_config:
  n8n_data:
```

Named volume `n8n_data` persists encryption key files, custom nodes, and runtime config.

The Caddy service's `depends_on` block must be updated to include `n8n` with `condition: service_healthy`.

## Database & Storage

### Postgres

- New database `n8n` with dedicated user `n8n` and its own password
- Init script `deploy/init-n8n-db.sql` mounted at `/docker-entrypoint-initdb.d/` for fresh deployments
- `update-server.sh` gets an idempotent `ALTER USER / CREATE DATABASE` block for n8n, following the Shlink pattern

### init-n8n-db.sql

```sql
CREATE USER n8n WITH PASSWORD 'n8n';
CREATE DATABASE n8n OWNER n8n;
```

Uses a hardcoded placeholder password, same pattern as `init-shlink-db.sql`. The `startup.sh` script regenerates this file at deploy time with the real password interpolated via bash heredoc. The `update-server.sh` script runs an idempotent `ALTER USER` to update the password on subsequent deploys.

### No Object Storage

n8n stores workflows and credentials in Postgres. Binary data (uploaded files in workflows) is stored in the `/home/node/.n8n` volume. No GCS/S3 integration needed.

## Backup

Add `n8n` database to the existing backup cron. Same pattern as Outline and Shlink. The backup script is generated by `startup.sh` (and `update-server.sh`) from a heredoc — the n8n dump commands must be added to that heredoc:

```bash
# Added alongside existing outline and shlink dumps:
docker compose exec -T postgres pg_dump -U n8n n8n | gzip > "/tmp/n8n-${TIMESTAMP}.sql.gz"
gcloud storage cp "/tmp/n8n-${TIMESTAMP}.sql.gz" "gs://${GCS_BUCKET}/backups/n8n-${TIMESTAMP}.sql.gz"
rm -f "/tmp/n8n-${TIMESTAMP}.sql.gz"
```

- Same 14-day retention policy
- Same Slack failure notification
- Same cleanup logic for old backups

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
| `N8N_HOST` | `automations.makenashville.org` |
| `N8N_PROTOCOL` | `https` |
| `N8N_PORT` | `5678` |
| `WEBHOOK_URL` | `https://automations.makenashville.org` |
| `N8N_ENCRYPTION_KEY` | (from GitHub Secret) |
| `N8N_USER_MANAGEMENT_DISABLED` | `true` |
| `N8N_DIAGNOSTICS_ENABLED` | `false` |
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

- `docker-compose.yml` — add n8n container; add `n8n_data` to top-level volumes; add `init-n8n-db.sql` mount on postgres; update Caddy `depends_on` to include n8n; update OAuth2 Proxy env vars (remove `REDIRECT_URL`, add `COOKIE_DOMAINS` and `WHITELIST_DOMAINS`)
- `docker-compose.local.yml` — add n8n for local dev (if applicable)
- `Caddyfile` — add `automations.makenashville.org` site block with webhook exceptions and `@unauthorized` redirect
- `Caddyfile.local` — add local n8n route (if applicable)
- `.env.example` — add `N8N_DB_PASSWORD`, `N8N_ENCRYPTION_KEY`
- `.env.production.example` — add n8n production variables
- `deploy/startup.sh` — **four heredocs** need n8n additions: (1) docker-compose.yml heredoc, (2) Caddyfile heredoc, (3) .env heredoc, (4) backup script heredoc. Also add init-n8n-db.sql heredoc generation.
- `deploy/update-server.sh` — add idempotent n8n database/user creation (`ALTER USER`/`CREATE DATABASE`), include n8n in compose heredoc, add n8n to backup script heredoc
- `.github/workflows/deploy.yml` — add `N8N_DB_PASSWORD` and `N8N_ENCRYPTION_KEY` to instance metadata; add SCP step to upload `deploy/init-n8n-db.sql` to the VM

### New

- `deploy/init-n8n-db.sql` — creates `n8n` database and user (fresh deployments only, placeholder password)

## New GitHub Secrets

- `N8N_DB_PASSWORD` — Postgres password for the n8n user
- `N8N_ENCRYPTION_KEY` — Encrypts credentials stored in n8n's database (generate with `openssl rand -hex 32`)

## Manual Prerequisites (Before Deploy)

1. Create DNS A record: `automations.makenashville.org` → VM's external IP
2. Add `N8N_DB_PASSWORD` and `N8N_ENCRYPTION_KEY` to GitHub repository secrets
3. Add `https://automations.makenashville.org/oauth2/callback` as an authorized redirect URI in the existing Google OAuth app (Cloud Console)
4. No new OAuth app or proxy instance needed — reuses the existing OAuth2 Proxy with cross-subdomain cookie config
