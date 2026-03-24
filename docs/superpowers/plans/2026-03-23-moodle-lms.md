# Moodle LMS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Moodle LMS to the Make Nashville Docker Compose stack with automated GRIT tool provisioning on course completion.

**Architecture:** Moodle 4.5 LTS joins the existing Caddy/Postgres/Redis stack on `learn.makenashville.org`. A lightweight Python sidecar (`grit-provisioner`) receives Moodle course completion webhooks and calls the GRIT automation API to provision equipment access. All deployment follows the existing pattern: `.env.production` → GCE metadata → deploy scripts → Docker Compose.

**Tech Stack:** Docker Compose, Bitnami Moodle 4.5, Python 3.12 (stdlib only), PostgreSQL 16, Redis 7, Caddy 2, GCP Compute Engine, GitHub Actions

**Spec:** `docs/superpowers/specs/2026-03-23-moodle-lms-design.md`

---

### Task 1: Create the GRIT Provisioner Service

The Python HTTP server that bridges Moodle webhooks to GRIT API calls. Uses only stdlib — no pip dependencies.

**Files:**
- Create: `deploy/grit-provisioner/server.py`
- Create: `deploy/grit-provisioner/server_test.py`
- Create: `deploy/grit-provisioner/course-tool-map.json`

- [ ] **Step 1: Write the test file**

Create `deploy/grit-provisioner/server_test.py` with tests covering:
- Health endpoint returns 200
- Valid webhook with correct secret provisions access and returns 200
- Missing/wrong webhook secret returns 403
- Course ID not in mapping returns 200 (ignored, not an error)
- Malformed JSON body returns 400

```python
import json
import os
import sys
import tempfile
import unittest
from http.client import HTTPConnection
from threading import Thread

# Set env vars before importing server
os.environ["GRIT_API_URL"] = "http://localhost:19876"
os.environ["GRIT_API_KEY"] = "test-grit-key"
os.environ["WEBHOOK_SECRET"] = "test-secret"
os.environ["SLACK_WEBHOOK_URL"] = ""

# Create temp course-tool-map
_MAP_FILE = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False)
json.dump({"3": {"grit_tool": "laser_cutter", "name": "Laser Cutter"}}, _MAP_FILE)
_MAP_FILE.flush()
os.environ["COURSE_TOOL_MAP_PATH"] = _MAP_FILE.name

sys.path.insert(0, os.path.dirname(__file__))
from server import create_server


class TestGritProvisioner(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = create_server(port=18765)
        cls.thread = Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def _request(self, method, path, body=None, headers=None):
        conn = HTTPConnection("localhost", 18765)
        hdrs = headers or {}
        if body is not None:
            hdrs["Content-Type"] = "application/json"
            body = json.dumps(body).encode()
        conn.request(method, path, body=body, headers=hdrs)
        resp = conn.getresponse()
        data = resp.read().decode()
        conn.close()
        return resp.status, data

    def test_health_returns_200(self):
        status, _ = self._request("GET", "/health")
        self.assertEqual(status, 200)

    def test_missing_secret_returns_403(self):
        status, _ = self._request("POST", "/webhook", body={"courseid": "3"})
        self.assertEqual(status, 403)

    def test_wrong_secret_returns_403(self):
        status, _ = self._request(
            "POST", "/webhook",
            body={"courseid": "3"},
            headers={"X-Webhook-Secret": "wrong"},
        )
        self.assertEqual(status, 403)

    def test_unmapped_course_returns_200(self):
        status, _ = self._request(
            "POST", "/webhook",
            body={"courseid": "999", "userid": "1", "useremail": "a@b.com"},
            headers={"X-Webhook-Secret": "test-secret"},
        )
        self.assertEqual(status, 200)

    def test_malformed_json_returns_400(self):
        conn = HTTPConnection("localhost", 18765)
        conn.request(
            "POST", "/webhook",
            body=b"not json",
            headers={"Content-Type": "application/json", "X-Webhook-Secret": "test-secret"},
        )
        resp = conn.getresponse()
        resp.read()
        conn.close()
        self.assertEqual(resp.status, 400)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests — verify they fail**

```bash
cd /Users/kevinhuber/src/infra
python3 deploy/grit-provisioner/server_test.py -v
```

Expected: `ModuleNotFoundError: No module named 'server'` (server.py doesn't exist yet)

- [ ] **Step 3: Implement server.py**

Create `deploy/grit-provisioner/server.py`:

```python
#!/usr/bin/env python3
"""GRIT Provisioner — bridges Moodle course completion webhooks to GRIT API."""

import json
import logging
import os
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("grit-provisioner")

GRIT_API_URL = os.environ.get("GRIT_API_URL", "")
GRIT_API_KEY = os.environ.get("GRIT_API_KEY", "")
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")
SLACK_WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "")
COURSE_TOOL_MAP_PATH = os.environ.get("COURSE_TOOL_MAP_PATH", "/app/course-tool-map.json")


def load_course_map():
    try:
        with open(COURSE_TOOL_MAP_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        log.warning("Could not load course-tool-map: %s", e)
        return {}


def notify_slack(message):
    if not SLACK_WEBHOOK_URL:
        return
    try:
        data = json.dumps({"text": message}).encode()
        req = urllib.request.Request(
            SLACK_WEBHOOK_URL, data=data,
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        log.error("Slack notification failed: %s", e)


def provision_grit(tool_id, user_email, tool_name):
    if not GRIT_API_URL:
        log.warning("GRIT_API_URL not configured — skipping provisioning")
        return
    try:
        data = json.dumps({"tool": tool_id, "user_email": user_email}).encode()
        req = urllib.request.Request(
            f"{GRIT_API_URL}/provision",
            data=data,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {GRIT_API_KEY}",
            },
        )
        urllib.request.urlopen(req, timeout=30)
        log.info("Provisioned %s for %s", tool_name, user_email)
        notify_slack(f"✅ Provisioned *{tool_name}* access for {user_email}")
    except Exception as e:
        log.error("GRIT provisioning failed for %s (%s): %s", user_email, tool_name, e)
        notify_slack(
            f"⚠️ Failed to provision *{tool_name}* for {user_email}. "
            f"Error: {e}. Staff should provision manually."
        )


class Handler(BaseHTTPRequestHandler):
    course_map = {}

    def log_message(self, format, *args):
        log.info(format, *args)

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
            self.end_headers()
            return

        # Validate webhook secret
        secret = self.headers.get("X-Webhook-Secret", "")
        if secret != WEBHOOK_SECRET:
            log.warning("Invalid webhook secret from %s", self.client_address[0])
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b'{"error":"forbidden"}')
            return

        # Parse body
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, ValueError):
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":"invalid json"}')
            return

        course_id = str(body.get("courseid", ""))
        user_email = body.get("useremail", "unknown")

        # Look up tool mapping
        mapping = self.course_map.get(course_id)
        if not mapping:
            log.info("Course %s not in tool map — ignoring", course_id)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":"ignored","reason":"unmapped course"}')
            return

        # Provision access
        provision_grit(mapping["grit_tool"], user_email, mapping["name"])
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"status":"provisioned"}')


def create_server(port=8000):
    Handler.course_map = load_course_map()
    server = HTTPServer(("0.0.0.0", port), Handler)
    return server


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8000"))
    server = create_server(port)
    log.info("GRIT Provisioner listening on port %d", port)
    server.serve_forever()
```

- [ ] **Step 4: Run tests — verify they pass**

```bash
cd /Users/kevinhuber/src/infra
python3 deploy/grit-provisioner/server_test.py -v
```

Expected: All 5 tests pass.

- [ ] **Step 5: Create course-tool-map.json**

Create `deploy/grit-provisioner/course-tool-map.json`:

```json
{
  "EXAMPLE_3": {"grit_tool": "laser_cutter", "name": "Laser Cutter"},
  "EXAMPLE_5": {"grit_tool": "cnc_router", "name": "CNC Router"}
}
```

Note: Keys are prefixed with `EXAMPLE_` to indicate they need to be replaced with real Moodle course IDs after courses are created.

- [ ] **Step 6: Commit**

```bash
git add deploy/grit-provisioner/server.py deploy/grit-provisioner/server_test.py deploy/grit-provisioner/course-tool-map.json
git commit -m "Add GRIT provisioner service for Moodle webhook → tool access"
```

---

### Task 2: Update docker-compose.yml

Add Moodle and grit-provisioner services, new volumes, and update Caddy's depends_on.

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Add moodle service**

Add after the `oauth2-proxy` service block (after line 99 in `docker-compose.yml`):

```yaml
  moodle:
    image: bitnami/moodle:4.5
    restart: unless-stopped
    environment:
      - MOODLE_DATABASE_TYPE=pgsql
      - MOODLE_DATABASE_HOST=postgres
      - MOODLE_DATABASE_PORT_NUMBER=5432
      - MOODLE_DATABASE_NAME=moodle
      - MOODLE_DATABASE_USER=moodle
      - MOODLE_DATABASE_PASSWORD=${MOODLE_DB_PASSWORD}
      - MOODLE_USERNAME=admin
      - MOODLE_PASSWORD=${MOODLE_ADMIN_PASSWORD}
      - MOODLE_EMAIL=${MOODLE_ADMIN_EMAIL}
      - MOODLE_HOST=learn.makenashville.org
      - MOODLE_SITE_NAME=Make Nashville Learning
      - MOODLE_PORT_NUMBER=8080
      - MOODLE_REVERSEPROXY=true
      - MOODLE_SSLPROXY=true
      - MOODLE_LANG=en
      - PHP_MEMORY_LIMIT=512M
    volumes:
      - moodle_data:/bitnami/moodledata
      - moodle_local:/bitnami/moodle/local
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/login/index.php || exit 1"]
      interval: 10s
      timeout: 10s
      retries: 10
      start_period: 120s
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
```

- [ ] **Step 2: Add grit-provisioner service**

Add after the moodle service:

```yaml
  grit-provisioner:
    image: python:3.12-alpine
    restart: unless-stopped
    volumes:
      - ./deploy/grit-provisioner:/app:ro
    command: ["python", "/app/server.py"]
    environment:
      - GRIT_API_URL=${GRIT_API_URL}
      - GRIT_API_KEY=${GRIT_API_KEY}
      - WEBHOOK_SECRET=${MOODLE_WEBHOOK_SECRET}
      - COURSE_TOOL_MAP_PATH=/app/course-tool-map.json
      - SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
    healthcheck:
      test: ["CMD-SHELL", "wget -qO /dev/null http://localhost:8000/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
```

- [ ] **Step 3: Add moodle to Caddy's depends_on**

In the `caddy` service's `depends_on` block (after line 22), add:

```yaml
      moodle:
        condition: service_healthy
```

- [ ] **Step 4: Add new volumes**

At the bottom of the `volumes:` section (after line 126), add:

```yaml
  moodle_data:
  moodle_local:
```

- [ ] **Step 5: Validate compose file**

```bash
cd /Users/kevinhuber/src/infra
docker compose config --quiet
```

Expected: No errors (exit code 0). Note: services won't start without env vars, but the config should parse.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml
git commit -m "Add Moodle and grit-provisioner to docker-compose stack"
```

---

### Task 3: Update Caddyfile

Add the `learn.makenashville.org` routing block.

**Files:**
- Modify: `Caddyfile`

- [ ] **Step 1: Add learn.makenashville.org block**

Append after the last block in `Caddyfile` (after line 47):

```caddy

learn.makenashville.org {
	header {
		X-Frame-Options SAMEORIGIN
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}
	reverse_proxy moodle:8080
}
```

- [ ] **Step 2: Validate Caddyfile syntax**

```bash
docker run --rm -v /Users/kevinhuber/src/infra/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
```

Expected: `Valid configuration` (may warn about unresolvable hosts — that's fine locally)

- [ ] **Step 3: Commit**

```bash
git add Caddyfile
git commit -m "Add Caddy routing for learn.makenashville.org"
```

---

### Task 4: Update Environment Configuration

Add new Moodle and GRIT variables to the production example file.

**Files:**
- Modify: `.env.production.example`

- [ ] **Step 1: Add Moodle section to .env.production.example**

Add before the `# Secrets` section (before the line `# ===================` / `# Secrets` around line 47):

```bash

# ===================
# Moodle LMS
# ===================
MOODLE_ADMIN_EMAIL=admin@makenashville.org

# ===================
# GRIT Automation
# ===================
GRIT_API_URL=
GRIT_API_KEY=
```

- [ ] **Step 2: Add Moodle secrets to the Secrets section**

Append to the end of the secrets section (after the `POSTGRES_PASSWORD=` line):

```bash
SHLINK_DB_PASSWORD=
MOODLE_DB_PASSWORD=
MOODLE_ADMIN_PASSWORD=
MOODLE_WEBHOOK_SECRET=
```

- [ ] **Step 3: Commit**

```bash
git add .env.production.example
git commit -m "Add Moodle and GRIT env vars to production example"
```

---

### Task 5: Update deploy/gcloud-setup.sh

Add secret auto-generation and metadata for Moodle/GRIT variables to both the update and new-install paths.

**Files:**
- Modify: `deploy/gcloud-setup.sh`

- [ ] **Step 1: Add secret auto-generation**

After line 45 (`SHLINK_DB_PASSWORD=...`), add:

```bash
MOODLE_DB_PASSWORD="${MOODLE_DB_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=')}"
MOODLE_ADMIN_PASSWORD="${MOODLE_ADMIN_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=')}"
MOODLE_WEBHOOK_SECRET="${MOODLE_WEBHOOK_SECRET:-$(openssl rand -hex 32)}"
```

- [ ] **Step 2: Add metadata to the update path**

In the `gcloud compute instances add-metadata` block for the update path (lines 67-85), the current last line (line 85) is `oauth2-google-admin-email="${OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL:-}"` with no trailing `,\`. First, append `,\` to that line to continue the metadata list, then add the new keys:

```bash
moodle-db-password="$MOODLE_DB_PASSWORD",\
moodle-admin-password="$MOODLE_ADMIN_PASSWORD",\
moodle-admin-email="${MOODLE_ADMIN_EMAIL:-}",\
moodle-webhook-secret="$MOODLE_WEBHOOK_SECRET",\
grit-api-url="${GRIT_API_URL:-}",\
grit-api-key="${GRIT_API_KEY:-}"
```

Note: The last line has no trailing comma+backslash (it's the final metadata key).

- [ ] **Step 3: Upload grit-provisioner files in the update path**

After the google-sa-key.json upload block (after line 111), add:

```bash
    # Upload GRIT provisioner files
    echo "Uploading GRIT provisioner files..."
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mkdir -p /opt/outline/grit-provisioner'
    gcloud compute scp "$SCRIPT_DIR/grit-provisioner/server.py" "$INSTANCE_NAME:~/grit-server.py" --zone="$ZONE"
    gcloud compute scp "$SCRIPT_DIR/grit-provisioner/course-tool-map.json" "$INSTANCE_NAME:~/grit-course-tool-map.json" --zone="$ZONE"
    gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/grit-server.py /opt/outline/grit-provisioner/server.py && sudo mv ~/grit-course-tool-map.json /opt/outline/grit-provisioner/course-tool-map.json && sudo chmod 644 /opt/outline/grit-provisioner/*'
```

- [ ] **Step 4: Add metadata to the new-install path**

In the `gcloud compute instances create` metadata block (lines 214-230), the current last line (line 230) is `oauth2-google-admin-email="${OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL:-}"` with no trailing `,\`. First, append `,\` to that line, then add the new keys:

```bash
moodle-db-password="$MOODLE_DB_PASSWORD",\
moodle-admin-password="$MOODLE_ADMIN_PASSWORD",\
moodle-admin-email="${MOODLE_ADMIN_EMAIL:-}",\
moodle-webhook-secret="$MOODLE_WEBHOOK_SECRET",\
grit-api-url="${GRIT_API_URL:-}",\
grit-api-key="${GRIT_API_KEY:-}"
```

- [ ] **Step 5: Add Moodle secrets to the "SAVE THESE SECRETS" output**

After line 251 (`echo "  POSTGRES_PASSWORD=$POSTGRES_PASSWORD"`), add:

```bash
echo "  MOODLE_DB_PASSWORD=$MOODLE_DB_PASSWORD"
echo "  MOODLE_ADMIN_PASSWORD=$MOODLE_ADMIN_PASSWORD"
echo "  MOODLE_WEBHOOK_SECRET=$MOODLE_WEBHOOK_SECRET"
```

- [ ] **Step 6: Verify script parses**

```bash
bash -n deploy/gcloud-setup.sh
```

Expected: No output (exit code 0 = no syntax errors)

- [ ] **Step 7: Commit**

```bash
git add deploy/gcloud-setup.sh
git commit -m "Add Moodle/GRIT secrets and metadata to GCP setup script"
```

---

### Task 6: Update deploy/update-server.sh

This is the largest change. Add metadata fetch, Moodle DB creation, update Caddyfile/docker-compose/.env templates, and extend the backup script.

**Files:**
- Modify: `deploy/update-server.sh`

- [ ] **Step 1: Add metadata fetch for new variables**

After line 29 (`OAUTH2_GOOGLE_ADMIN_EMAIL=...`), add:

```bash
MOODLE_DB_PASSWORD=$(get_metadata "moodle-db-password")
MOODLE_ADMIN_PASSWORD=$(get_metadata "moodle-admin-password")
MOODLE_ADMIN_EMAIL=$(get_metadata "moodle-admin-email")
MOODLE_WEBHOOK_SECRET=$(get_metadata "moodle-webhook-secret")
GRIT_API_URL=$(get_metadata "grit-api-url")
GRIT_API_KEY=$(get_metadata "grit-api-key")
```

- [ ] **Step 2: Add Moodle DB creation block**

After the Shlink DB creation block (after line 38), add:

```bash

# Create Moodle database if it doesn't exist on existing Postgres instances
echo "Ensuring Moodle database exists..."
sudo docker compose exec -T postgres psql -U outline -tc "SELECT 1 FROM pg_roles WHERE rolname='moodle'" | grep -q 1 || \
    sudo docker compose exec -T postgres psql -U outline -c "CREATE USER moodle WITH PASSWORD '${MOODLE_DB_PASSWORD}';"
sudo docker compose exec -T postgres psql -U outline -c "ALTER USER moodle WITH PASSWORD '${MOODLE_DB_PASSWORD}';"
sudo docker compose exec -T postgres psql -U outline -tc "SELECT 1 FROM pg_database WHERE datname='moodle'" | grep -q 1 || \
    sudo docker compose exec -T postgres psql -U outline -c "CREATE DATABASE moodle OWNER moodle;"
```

- [ ] **Step 3: Add learn.makenashville.org to Caddyfile template**

In the Caddyfile heredoc, append before the closing `CADDY` delimiter (before line 91 which is `CADDY`):

```caddy

learn.makenashville.org {
	header {
		X-Frame-Options SAMEORIGIN
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}
	reverse_proxy moodle:8080
}
```

- [ ] **Step 4: Add Moodle vars to .env template**

In the `.env` heredoc, append before the closing `ENV` delimiter (before line 135 which is `ENV`):

```bash

# Moodle
MOODLE_DB_PASSWORD=${MOODLE_DB_PASSWORD}
MOODLE_ADMIN_PASSWORD=${MOODLE_ADMIN_PASSWORD}
MOODLE_ADMIN_EMAIL=${MOODLE_ADMIN_EMAIL}
MOODLE_WEBHOOK_SECRET=${MOODLE_WEBHOOK_SECRET}

# GRIT
GRIT_API_URL=${GRIT_API_URL}
GRIT_API_KEY=${GRIT_API_KEY}
```

- [ ] **Step 5: Add moodle and grit-provisioner to docker-compose template**

In the docker-compose heredoc, add the moodle service after the oauth2-proxy block and before the postgres block. Add the grit-provisioner service after moodle. Add `moodle: condition: service_healthy` to caddy's depends_on. Add `moodle_data:` and `moodle_local:` to the volumes section at the bottom.

The moodle service block to add:

```yaml
  moodle:
    image: bitnami/moodle:4.5
    restart: unless-stopped
    environment:
      - MOODLE_DATABASE_TYPE=pgsql
      - MOODLE_DATABASE_HOST=postgres
      - MOODLE_DATABASE_PORT_NUMBER=5432
      - MOODLE_DATABASE_NAME=moodle
      - MOODLE_DATABASE_USER=moodle
      - MOODLE_DATABASE_PASSWORD=${MOODLE_DB_PASSWORD}
      - MOODLE_USERNAME=admin
      - MOODLE_PASSWORD=${MOODLE_ADMIN_PASSWORD}
      - MOODLE_EMAIL=${MOODLE_ADMIN_EMAIL}
      - MOODLE_HOST=learn.makenashville.org
      - MOODLE_SITE_NAME=Make Nashville Learning
      - MOODLE_PORT_NUMBER=8080
      - MOODLE_REVERSEPROXY=true
      - MOODLE_SSLPROXY=true
      - MOODLE_LANG=en
      - PHP_MEMORY_LIMIT=512M
    volumes:
      - moodle_data:/bitnami/moodledata
      - moodle_local:/bitnami/moodle/local
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/login/index.php || exit 1"]
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
      test: ["CMD-SHELL", "wget -qO /dev/null http://localhost:8000/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
```

Note: In update-server.sh's template, the grit-provisioner volume path is `./grit-provisioner:/app:ro` (relative to `/opt/outline/` on the server), unlike the local docker-compose.yml which uses `./deploy/grit-provisioner:/app:ro`.

Add to caddy's depends_on:

```yaml
      moodle:
        condition: service_healthy
```

Add to the volumes block at the bottom:

```yaml
  moodle_data:
  moodle_local:
```

- [ ] **Step 6: Add Moodle DB to backup script**

In the backup script heredoc (after the Shlink backup block around line 298-299), add:

```bash

# Backup Moodle database
MOODLE_BACKUP_FILE="/tmp/moodle-\${TIMESTAMP}.sql.gz"
docker compose -f /opt/outline/docker-compose.yml exec -T postgres pg_dump -U moodle moodle | gzip > "\${MOODLE_BACKUP_FILE}"
gcloud storage cp "\${MOODLE_BACKUP_FILE}" "\${BUCKET}/moodle-\${TIMESTAMP}.sql.gz"
rm -f "\${MOODLE_BACKUP_FILE}"

# Backup Moodle data volume
MOODLEDATA_BACKUP_FILE="/tmp/moodledata-\${TIMESTAMP}.tar.gz"
docker run --rm -v moodle_data:/data:ro -v /tmp:/backup alpine tar czf "/backup/moodledata-\${TIMESTAMP}.tar.gz" -C /data .
gcloud storage cp "\${MOODLEDATA_BACKUP_FILE}" "\${BUCKET}/moodledata-\${TIMESTAMP}.tar.gz"
rm -f "\${MOODLEDATA_BACKUP_FILE}"
```

Also update the completion log line to include moodle:

```bash
echo "[\$(date)] Backup complete: outline, shlink, and moodle \${TIMESTAMP}"
```

- [ ] **Step 7: Verify script parses**

```bash
bash -n deploy/update-server.sh
```

Expected: No output (exit code 0)

- [ ] **Step 8: Commit**

```bash
git add deploy/update-server.sh
git commit -m "Add Moodle service, DB, and backups to update-server.sh"
```

---

### Task 7: Update deploy/startup.sh

Add metadata fetch and update the docker-compose, Caddyfile, and .env templates for first-boot.

**Files:**
- Modify: `deploy/startup.sh`

- [ ] **Step 1: Add metadata fetch for new variables**

After line 66 (`OAUTH2_GOOGLE_ADMIN_EMAIL=...`), add:

```bash
MOODLE_DB_PASSWORD=$(get_metadata "moodle-db-password")
MOODLE_ADMIN_PASSWORD=$(get_metadata "moodle-admin-password")
MOODLE_ADMIN_EMAIL=$(get_metadata "moodle-admin-email")
MOODLE_WEBHOOK_SECRET=$(get_metadata "moodle-webhook-secret")
GRIT_API_URL=$(get_metadata "grit-api-url")
GRIT_API_KEY=$(get_metadata "grit-api-key")
```

- [ ] **Step 2: Create grit-provisioner files on first boot**

After the Shlink DB init script creation (after the `SHLINKSQL` heredoc closing around line 421), add a block that creates the grit-provisioner directory and files. On first boot, the files are not uploaded via SCP (that only happens in the update path), so they must be created inline:

```bash
# Create GRIT provisioner directory and files
log "Creating GRIT provisioner..."
mkdir -p grit-provisioner
```

Then create `grit-provisioner/server.py` using a heredoc with the full server code from Task 1, Step 3. Use a **quoted** heredoc delimiter (`<<'GRITPY'`) so that bash does not expand variables in the Python code.

Also create `grit-provisioner/course-tool-map.json` with the example mapping:

```bash
cat > grit-provisioner/course-tool-map.json <<'GRITMAP'
{
  "EXAMPLE_3": {"grit_tool": "laser_cutter", "name": "Laser Cutter"},
  "EXAMPLE_5": {"grit_tool": "cnc_router", "name": "CNC Router"}
}
GRITMAP
```

- [ ] **Step 3: Add moodle + grit-provisioner to docker-compose template**

Mirror the same service definitions from Task 6, Step 5 into the startup.sh docker-compose heredoc. Add the services after oauth2-proxy (before postgres). Add `moodle: condition: service_healthy` to caddy's depends_on. Add `moodle_data:` and `moodle_local:` to the volumes block.

**Important:** The grit-provisioner volume path in the startup.sh template must be `./grit-provisioner:/app:ro` (relative to `/opt/outline/`), NOT `./deploy/grit-provisioner:/app:ro` (which is the local dev path).

- [ ] **Step 4: Add learn.makenashville.org to Caddyfile template**

Mirror the Caddyfile block from Task 6, Step 3 into the startup.sh Caddyfile heredoc.

- [ ] **Step 5: Add Moodle/GRIT vars to .env template**

Mirror the .env additions from Task 6, Step 4 into the startup.sh .env heredoc.

- [ ] **Step 6: Verify script parses**

```bash
bash -n deploy/startup.sh
```

Expected: No output (exit code 0)

- [ ] **Step 7: Commit**

```bash
git add deploy/startup.sh
git commit -m "Add Moodle service to first-boot startup script"
```

---

### Task 8: Update GitHub Actions Workflow

Add new secrets to metadata and upload grit-provisioner files to the server.

**Files:**
- Modify: `.github/workflows/deploy.yml`

- [ ] **Step 1: Add new metadata keys**

In the `Update instance metadata` step (lines 44-62), the current last line (line 62) is `oauth2-google-admin-email="${{ secrets.OAUTH2_PROXY_GOOGLE_ADMIN_EMAIL }}"` with no trailing `,\`. First, append `,\` to that line, then add the new keys:

```yaml
          moodle-db-password="${{ secrets.MOODLE_DB_PASSWORD }}",\
          moodle-admin-password="${{ secrets.MOODLE_ADMIN_PASSWORD }}",\
          moodle-admin-email="${{ secrets.MOODLE_ADMIN_EMAIL }}",\
          moodle-webhook-secret="${{ secrets.MOODLE_WEBHOOK_SECRET }}",\
          grit-api-url="${{ secrets.GRIT_API_URL }}",\
          grit-api-key="${{ secrets.GRIT_API_KEY }}"
```

Note: The last line has no trailing comma+backslash.

- [ ] **Step 2: Add grit-provisioner file uploads**

In the `Upload files to server` step (lines 64-73), add after the google-sa-key.json upload:

```yaml
          gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mkdir -p /opt/outline/grit-provisioner'
          gcloud compute scp deploy/grit-provisioner/server.py "$INSTANCE_NAME:~/grit-server.py" --zone="$ZONE"
          gcloud compute scp deploy/grit-provisioner/course-tool-map.json "$INSTANCE_NAME:~/grit-course-tool-map.json" --zone="$ZONE"
          gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/grit-server.py /opt/outline/grit-provisioner/server.py && sudo mv ~/grit-course-tool-map.json /opt/outline/grit-provisioner/course-tool-map.json && sudo chmod 644 /opt/outline/grit-provisioner/*'
```

- [ ] **Step 3: Validate workflow YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml'))"
```

Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "Add Moodle/GRIT secrets and file uploads to deploy workflow"
```

---

### Task 9: Update Monitoring

Add the `learn.makenashville.org` uptime check.

**Files:**
- Modify: `deploy/monitoring.sh`

- [ ] **Step 1: Add learn uptime check**

On line 48, update the `CHECK_NAMES` array:

```bash
CHECK_NAMES=(uptime-wiki uptime-grithub uptime-members uptime-website uptime-learn)
```

On line 49, update the `CHECK_URLS` array:

```bash
CHECK_URLS=("https://wiki.makenashville.org" "https://makenashville.grithub.app/" "https://members.makenashville.org/" "https://makenashville.org" "https://learn.makenashville.org/login/index.php")
```

- [ ] **Step 2: Verify script parses**

```bash
bash -n deploy/monitoring.sh
```

Expected: No output (exit code 0)

- [ ] **Step 3: Commit**

```bash
git add deploy/monitoring.sh
git commit -m "Add learn.makenashville.org uptime check"
```

---

### Task 10: Final Validation

Run all validation checks and verify the complete change set.

**Files:** None (validation only)

- [ ] **Step 1: Run grit-provisioner tests**

```bash
python3 deploy/grit-provisioner/server_test.py -v
```

Expected: All tests pass.

- [ ] **Step 2: Validate docker-compose**

```bash
docker compose config --quiet 2>&1 || true
```

Expected: Parses without syntax errors (may warn about missing env vars).

- [ ] **Step 3: Validate all shell scripts**

```bash
bash -n deploy/gcloud-setup.sh && bash -n deploy/update-server.sh && bash -n deploy/startup.sh && bash -n deploy/monitoring.sh
```

Expected: No output (all parse cleanly).

- [ ] **Step 4: Review git log**

```bash
git log --oneline -10
```

Verify all commits from this plan are present and correctly ordered.
