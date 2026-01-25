# Outline Docker Compose for Make Nashville

Local development setup for [Outline](https://www.getoutline.com/) wiki, for Tim to try on his machine. 

## Services

- **Outline** - Wiki application
- **Caddy** - Reverse proxy with HTTPS
- **PostgreSQL** - Database
- **Redis** - Caching/sessions
- **MinIO** - S3-compatible file storage

## Setup

1. Install mkcert and generate local certificates:
   ```bash
   brew install mkcert
   mkcert -install
   mkcert localhost
   ```

2. Copy and configure environment:
   ```bash
   cp .env.example .env
   ```

3. Generate secrets and update `.env`:
   ```bash
   openssl rand -hex 32  # Run twice for SECRET_KEY and UTILS_SECRET
   ```

4. Configure Slack authentication in `.env`:
   - Create a Slack app at https://api.slack.com/apps
   - Add redirect URL: `https://localhost/auth/slack.callback`
   - Add User Token Scopes: `identity.avatar`, `identity.basic`, `identity.email`, `identity.team`
   - Copy Client ID and Client Secret to `.env`

5. Start services:
   ```bash
   docker compose up -d
   ```

6. Create MinIO bucket:
   ```bash
   docker compose exec minio mc alias set local http://localhost:9000 minioadmin minioadmin
   docker compose exec minio mc mb local/outline
   ```

7. Access at https://localhost

## Ports

| Service | Port |
|---------|------|
| Outline (via Caddy) | 443 |
| MinIO API | 9000 |
| MinIO Console | 9001 |
