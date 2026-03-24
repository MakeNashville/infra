#!/bin/bash
set -euo pipefail

# GCP Compute Engine Startup Script for Make Nashville Wiki (Outline)
# This script runs on first boot to set up the server

LOG_FILE="/var/log/outline-setup.log"
APP_DIR="/opt/outline"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "Starting Outline wiki setup..."

# Wait for network
sleep 10

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    log "Installing Docker..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    log "Docker installed successfully"
else
    log "Docker already installed"
fi

# Create application directory
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# Fetch configuration from instance metadata
log "Fetching configuration from instance metadata..."
METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
METADATA_HEADER="Metadata-Flavor: Google"

get_metadata() {
    curl -sf -H "$METADATA_HEADER" "$METADATA_URL/$1" || echo ""
}

# Required metadata attributes
DOMAIN=$(get_metadata "domain")
SECRET_KEY=$(get_metadata "secret-key")
UTILS_SECRET=$(get_metadata "utils-secret")
POSTGRES_PASSWORD=$(get_metadata "postgres-password")
GCS_ACCESS_KEY=$(get_metadata "gcs-access-key")
GCS_SECRET_KEY=$(get_metadata "gcs-secret-key")
GCS_BUCKET=$(get_metadata "gcs-bucket")
SLACK_CLIENT_ID=$(get_metadata "slack-client-id")
SLACK_CLIENT_SECRET=$(get_metadata "slack-client-secret")
SHLINK_DB_PASSWORD=$(get_metadata "shlink-db-password")
SLACK_WEBHOOK_URL=$(get_metadata "slack-webhook-url")
OAUTH2_CLIENT_ID=$(get_metadata "oauth2-client-id")
OAUTH2_CLIENT_SECRET=$(get_metadata "oauth2-client-secret")
OAUTH2_COOKIE_SECRET=$(get_metadata "oauth2-cookie-secret")
OAUTH2_GOOGLE_ADMIN_EMAIL=$(get_metadata "oauth2-google-admin-email")
MOODLE_DB_PASSWORD=$(get_metadata "moodle-db-password")
MOODLE_ADMIN_PASSWORD=$(get_metadata "moodle-admin-password")
MOODLE_ADMIN_EMAIL=$(get_metadata "moodle-admin-email")
MOODLE_WEBHOOK_SECRET=$(get_metadata "moodle-webhook-secret")
GRIT_API_URL=$(get_metadata "grit-api-url")
GRIT_API_KEY=$(get_metadata "grit-api-key")

# Validate required fields
if [[ -z "$DOMAIN" || -z "$SECRET_KEY" || -z "$UTILS_SECRET" ]]; then
    log "ERROR: Missing required metadata attributes (domain, secret-key, utils-secret)"
    exit 1
fi

log "Domain: $DOMAIN"

# Create docker-compose.yml
log "Creating docker-compose.yml..."
cat > docker-compose.yml <<COMPOSE
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
      - OAUTH2_PROXY_REDIRECT_URL=https://links.makenashville.org/oauth2/callback
      - OAUTH2_PROXY_UPSTREAM=static://202
      - OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
      - OAUTH2_PROXY_REVERSE_PROXY=true

  moodle:
    build: ./moodle-docker
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
      test: ["CMD-SHELL", "wget -qO /dev/null http://localhost:8000/health || exit 1"]
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
  moodle_data:
  moodle_local:
COMPOSE

# Create patched S3Storage.js (adds Content-Disposition condition for GCS compatibility)
log "Creating S3Storage.js patch..."
cat > S3Storage.js <<'S3EOF'
"use strict";

Object.defineProperty(exports, "__esModule", {
  value: true
});
exports.default = void 0;
var _nodePath = _interopRequireDefault(require("node:path"));
var _clientS = require("@aws-sdk/client-s3");
var _libStorage = require("@aws-sdk/lib-storage");
require("@aws-sdk/signature-v4-crt");
var _s3PresignedPost = require("@aws-sdk/s3-presigned-post");
var _s3RequestPresigner = require("@aws-sdk/s3-request-presigner");
var _fsExtra = _interopRequireDefault(require("fs-extra"));
var _invariant = _interopRequireDefault(require("invariant"));
var _compact = _interopRequireDefault(require("lodash/compact"));
var _tmp = _interopRequireDefault(require("tmp"));
var _env = _interopRequireDefault(require("./../../env"));
var _Logger = _interopRequireDefault(require("./../../logging/Logger"));
var _BaseStorage = _interopRequireDefault(require("./BaseStorage"));
function _interopRequireDefault(e) { return e && e.__esModule ? e : { default: e }; }
function _defineProperty(e, r, t) { return (r = _toPropertyKey(r)) in e ? Object.defineProperty(e, r, { value: t, enumerable: !0, configurable: !0, writable: !0 }) : e[r] = t, e; }
function _toPropertyKey(t) { var i = _toPrimitive(t, "string"); return "symbol" == typeof i ? i : i + ""; }
function _toPrimitive(t, r) { if ("object" != typeof t || !t) return t; var e = t[Symbol.toPrimitive]; if (void 0 !== e) { var i = e.call(t, r || "default"); if ("object" != typeof i) return i; throw new TypeError("@@toPrimitive must return a primitive value."); } return ("string" === r ? String : Number)(t); } // https://github.com/aws/aws-sdk-js-v3#functionality-requiring-aws-common-runtime-crt
class S3Storage extends _BaseStorage.default {
  constructor() {
    var _this;
    super();
    _this = this;
    _defineProperty(this, "store", async _ref => {
      let {
        body,
        contentType,
        key,
        acl
      } = _ref;
      const upload = new _libStorage.Upload({
        client: this.client,
        params: {
          ...(acl && {
            ACL: acl
          }),
          Bucket: this.getBucket(),
          Key: key,
          ContentType: contentType,
          // See bug, if used causes large files to hang: https://github.com/aws/aws-sdk-js-v3/issues/3915
          // ContentLength: contentLength,
          ContentDisposition: this.getContentDisposition(contentType),
          Body: body
        }
      });
      await upload.done();
      const endpoint = this.getPublicEndpoint(true);
      return `${endpoint}/${key}`;
    });
    _defineProperty(this, "getSignedUrl", async function (key) {
      let expiresIn = arguments.length > 1 && arguments[1] !== undefined ? arguments[1] : S3Storage.defaultSignedUrlExpires;
      const isDocker = _env.default.AWS_S3_UPLOAD_BUCKET_URL.match(/http:\/\/s3:/);
      const params = {
        Bucket: _this.getBucket(),
        Key: key
      };
      if (isDocker) {
        return `${_this.getPublicEndpoint()}/${key}`;
      } else {
        // Ensure expiration does not exceed AWS S3 Signature V4 limit of 7 days
        const clampedExpiresIn = Math.min(expiresIn, S3Storage.maxSignedUrlExpires);
        const command = new _clientS.GetObjectCommand(params);
        const url = await (0, _s3RequestPresigner.getSignedUrl)(_this.client, command, {
          expiresIn: clampedExpiresIn
        });
        if (_env.default.AWS_S3_ACCELERATE_URL) {
          return url.replace(_env.default.AWS_S3_UPLOAD_BUCKET_URL, _env.default.AWS_S3_ACCELERATE_URL);
        }
        return url;
      }
    });
    _defineProperty(this, "moveFile", async (fromKey, toKey) => {
      await this.client.send(new _clientS.CopyObjectCommand({
        Bucket: this.getBucket(),
        CopySource: `${_env.default.AWS_S3_UPLOAD_BUCKET_NAME}/${fromKey}`,
        Key: toKey
      }));
      await this.client.send(new _clientS.DeleteObjectCommand({
        Bucket: this.getBucket(),
        Key: fromKey
      }));
    });
    _defineProperty(this, "client", void 0);
    this.client = new _clientS.S3Client({
      bucketEndpoint: _env.default.AWS_S3_ACCELERATE_URL ? true : false,
      forcePathStyle: _env.default.AWS_S3_FORCE_PATH_STYLE,
      region: _env.default.AWS_REGION,
      endpoint: this.getEndpoint()
    });
  }
  async getPresignedPost(_ctx, key, acl, maxUploadSize) {
    let contentType = arguments.length > 4 && arguments[4] !== undefined ? arguments[4] : "image";
    const params = {
      Bucket: _env.default.AWS_S3_UPLOAD_BUCKET_NAME,
      Key: key,
      Conditions: (0, _compact.default)([["content-length-range", 0, maxUploadSize], ["starts-with", "$Content-Type", contentType], ["starts-with", "$Cache-Control", ""], ["starts-with", "$Content-Disposition", ""]]),
      Fields: {
        "Content-Disposition": this.getContentDisposition(contentType),
        key,
      },
      Expires: 3600
    };
    return (0, _s3PresignedPost.createPresignedPost)(this.client, params);
  }
  getPublicEndpoint(isServerUpload) {
    if (_env.default.AWS_S3_ACCELERATE_URL) {
      return _env.default.AWS_S3_ACCELERATE_URL;
    }
    (0, _invariant.default)(_env.default.AWS_S3_UPLOAD_BUCKET_NAME, "AWS_S3_UPLOAD_BUCKET_NAME is required");

    // lose trailing slash if there is one and convert fake-s3 url to localhost
    // for access outside of docker containers in local development
    const isDocker = _env.default.AWS_S3_UPLOAD_BUCKET_URL.match(/http:\/\/s3:/);
    const host = _env.default.AWS_S3_UPLOAD_BUCKET_URL.replace("s3:", "localhost:").replace(/\/$/, "");

    // support old path-style S3 uploads and new virtual host uploads by checking
    // for the bucket name in the endpoint url before appending.
    const isVirtualHost = host.includes(_env.default.AWS_S3_UPLOAD_BUCKET_NAME);
    if (isVirtualHost) {
      return host;
    }
    return `${host}/${isServerUpload && isDocker ? "s3/" : ""}${_env.default.AWS_S3_UPLOAD_BUCKET_NAME}`;
  }
  getUploadUrl(isServerUpload) {
    return this.getPublicEndpoint(isServerUpload);
  }
  getUrlForKey(key) {
    return `${this.getPublicEndpoint()}/${key}`;
  }
  async deleteFile(key) {
    await this.client.send(new _clientS.DeleteObjectCommand({
      Bucket: this.getBucket(),
      Key: key
    }));
  }
  getFileHandle(key) {
    return new Promise((resolve, reject) => {
      _tmp.default.dir((err, tmpDir) => {
        if (err) {
          return reject(err);
        }
        const tmpFile = _nodePath.default.join(tmpDir, "tmp");
        const dest = _fsExtra.default.createWriteStream(tmpFile);
        dest.on("error", reject);
        dest.on("finish", () => resolve({
          path: tmpFile,
          cleanup: () => _fsExtra.default.rm(tmpFile)
        }));
        void this.getFileStream(key).then(stream => {
          if (!stream) {
            return reject(new Error("No stream available"));
          }
          stream.on("error", error => {
            dest.end();
            reject(error);
          }).pipe(dest);
        });
      });
    });
  }
  getFileExists(key) {
    return this.client.send(new _clientS.HeadObjectCommand({
      Bucket: this.getBucket(),
      Key: key
    })).then(() => true).catch(() => false);
  }
  getFileStream(key, range) {
    return this.client.send(new _clientS.GetObjectCommand({
      Bucket: this.getBucket(),
      Key: key,
      Range: range ? `bytes=${range.start}-${range.end}` : undefined
    })).then(item => item.Body).catch(err => {
      _Logger.default.error("Error getting file stream from S3 ", err, {
        key
      });
      return null;
    });
  }
  getEndpoint() {
    if (_env.default.AWS_S3_ACCELERATE_URL) {
      return _env.default.AWS_S3_ACCELERATE_URL;
    }

    // support old path-style S3 uploads and new virtual host uploads by
    // checking for the bucket name in the endpoint url.
    if (_env.default.AWS_S3_UPLOAD_BUCKET_NAME) {
      const url = new URL(_env.default.AWS_S3_UPLOAD_BUCKET_URL);
      if (url.hostname.startsWith(_env.default.AWS_S3_UPLOAD_BUCKET_NAME + ".")) {
        _Logger.default.warn("AWS_S3_UPLOAD_BUCKET_URL contains the bucket name, this configuration combination will always point to AWS.\nRename your bucket or hostname if not using AWS S3.\nSee: https://github.com/outline/outline/issues/8025");
        return undefined;
      }
    }
    return _env.default.AWS_S3_UPLOAD_BUCKET_URL;
  }
  getBucket() {
    return _env.default.AWS_S3_ACCELERATE_URL || _env.default.AWS_S3_UPLOAD_BUCKET_NAME || "";
  }
}
exports.default = S3Storage;
S3EOF

# Create Shlink database init script with production password
log "Creating Shlink database init script..."
cat > init-shlink-db.sql <<SHLINKSQL
CREATE USER shlink WITH PASSWORD '${SHLINK_DB_PASSWORD}';
CREATE DATABASE shlink OWNER shlink;
SHLINKSQL

# Create GRIT provisioner directory and files
log "Creating GRIT provisioner..."
mkdir -p grit-provisioner

cat > grit-provisioner/server.py <<'GRITPY'
#!/usr/bin/env python3
"""GRIT Provisioner — bridges Moodle course completion webhooks to GRIT API."""

import hmac
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
        notify_slack(f"Provisioned *{tool_name}* access for {user_email}")
    except Exception as e:
        log.error("GRIT provisioning failed for %s (%s): %s", user_email, tool_name, e)
        notify_slack(
            f"Failed to provision *{tool_name}* for {user_email}. "
            f"Error: {e}. Staff should provision manually."
        )


class Handler(BaseHTTPRequestHandler):
    course_map = {}

    def log_message(self, format, *args):
        log.info(format, *args)

    def _respond(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _drain_request_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            self.rfile.read(length)

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/webhook":
            self._drain_request_body()
            self.send_response(404)
            self.end_headers()
            return

        # Validate webhook secret
        secret = self.headers.get("X-Webhook-Secret", "")
        if not hmac.compare_digest(secret, WEBHOOK_SECRET):
            self._drain_request_body()
            log.warning("Invalid webhook secret from %s", self.client_address[0])
            self._respond(403, {"error": "forbidden"})
            return

        # Parse body
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, ValueError):
            self._respond(400, {"error": "invalid json"})
            return

        course_id = str(body.get("courseid", ""))
        user_email = body.get("useremail", "unknown")

        # Look up tool mapping
        mapping = self.course_map.get(course_id)
        if not mapping:
            log.info("Course %s not in tool map — ignoring", course_id)
            self._respond(200, {"status": "ignored", "reason": "unmapped course"})
            return

        # Provision access
        provision_grit(mapping["grit_tool"], user_email, mapping["name"])
        self._respond(200, {"status": "provisioned"})


def create_server(port=8000):
    if not WEBHOOK_SECRET:
        raise RuntimeError("WEBHOOK_SECRET environment variable must be set")
    Handler.course_map = load_course_map()
    server = HTTPServer(("0.0.0.0", port), Handler)
    return server


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8000"))
    server = create_server(port)
    log.info("GRIT Provisioner listening on port %d", port)
    server.serve_forever()
GRITPY

cat > grit-provisioner/course-tool-map.json <<'GRITMAP'
{
  "EXAMPLE_3": {"grit_tool": "laser_cutter", "name": "Laser Cutter"},
  "EXAMPLE_5": {"grit_tool": "cnc_router", "name": "CNC Router"}
}
GRITMAP

# Create Moodle Docker build context
log "Creating Moodle Docker image files..."
mkdir -p moodle-docker

cat > moodle-docker/Dockerfile <<'MOODLEDOCKERFILE'
FROM moodlehq/moodle-php-apache:8.3

# Download Moodle 4.5 LTS (supported until October 2027)
RUN curl -fsSL -L https://download.moodle.org/download.php/direct/stable405/moodle-latest-405.tgz \
    | tar -xz --strip-components=1 -C /var/www/html \
    && chown -R www-data:www-data /var/www/html \
    && chmod 0770 /var/www/moodledata

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
MOODLEDOCKERFILE

cat > moodle-docker/entrypoint.sh <<'MOODLEENTRY'
#!/bin/bash
set -e

# Set Apache document root (required by moodlehq base image's Apache config)
export APACHE_DOCUMENT_ROOT=/var/www/html

# Generate config.php from environment variables
cat > /var/www/html/config.php <<MOODLECFG
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = 'pgsql';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = '${MOODLE_DB_HOST:-postgres}';
\$CFG->dbname    = '${MOODLE_DB_NAME:-moodle}';
\$CFG->dbuser    = '${MOODLE_DB_USER:-moodle}';
\$CFG->dbpass    = '${MOODLE_DB_PASSWORD}';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = [
    'dbpersist' => false,
    'dbsocket'  => false,
    'dbport'    => '${MOODLE_DB_PORT:-5432}',
];

\$CFG->wwwroot   = '${MOODLE_WWWROOT:-https://learn.makenashville.org}';
\$CFG->dataroot  = '/var/www/moodledata';
\$CFG->admin     = 'admin';

// Redis sessions (DB index 3)
\$CFG->session_handler_class        = '\core\session\redis';
\$CFG->session_redis_host           = '${MOODLE_REDIS_HOST:-redis}';
\$CFG->session_redis_port           = ${MOODLE_REDIS_PORT:-6379};
\$CFG->session_redis_database       = ${MOODLE_REDIS_DB:-3};
\$CFG->session_redis_prefix         = 'mdl_sess_';
\$CFG->session_redis_acquire_lock_timeout = 120;
\$CFG->session_redis_lock_expire    = 7200;
\$CFG->session_redis_lock_retry     = 100;

// Reverse proxy (behind Caddy)
\$CFG->reverseproxy = true;
\$CFG->sslproxy     = true;

require_once(__DIR__ . '/lib/setup.php');
MOODLECFG

chown www-data:www-data /var/www/html/config.php

# Run Moodle install if database tables don't exist yet
# Use su instead of sudo (not available in this image)
if ! su -s /bin/bash www-data -c "php /var/www/html/admin/cli/check_database_schema.php" > /dev/null 2>&1; then
    echo "First boot detected — installing Moodle..."
    su -s /bin/bash www-data -c "php /var/www/html/admin/cli/install_database.php \
        --agree-license \
        --fullname='Make Nashville Learning' \
        --shortname='MNLearn' \
        --adminuser=admin \
        --adminpass='${MOODLE_ADMIN_PASSWORD:-changeme}' \
        --adminemail='${MOODLE_ADMIN_EMAIL:-admin@makenashville.org}'" \
        || echo "Install failed or already installed"
fi

# Start cron in background (every minute)
(while true; do
    su -s /bin/bash www-data -c "php /var/www/html/admin/cli/cron.php" > /dev/null 2>&1
    sleep 60
done) &

# Start Apache in foreground
exec apache2-foreground
MOODLEENTRY
chmod +x moodle-docker/entrypoint.sh

# Create Caddyfile
log "Creating Caddyfile..."
cat > Caddyfile <<CADDY
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

learn.makenashville.org {
	header {
		X-Frame-Options SAMEORIGIN
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}
	reverse_proxy moodle:80
}
CADDY

# Create .env file
log "Creating .env file..."
cat > .env <<ENV
# Domain Configuration
DOMAIN=${DOMAIN}
URL=https://${DOMAIN}

# Outline
NODE_ENV=production
SECRET_KEY=${SECRET_KEY}
UTILS_SECRET=${UTILS_SECRET}
PORT=3000
HOST=0.0.0.0

# Database
DATABASE_URL=postgres://outline:${POSTGRES_PASSWORD:-outline}@postgres:5432/outline
PGSSLMODE=disable
POSTGRES_USER=outline
POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-outline}
POSTGRES_DB=outline

# Redis
REDIS_URL=redis://redis:6379

# Storage (Google Cloud Storage)
FILE_STORAGE=s3
FILE_STORAGE_UPLOAD_MAX_SIZE=262144000
AWS_S3_UPLOAD_BUCKET_NAME=${GCS_BUCKET:-outline}
AWS_S3_ACL=private

AWS_ACCESS_KEY_ID=${GCS_ACCESS_KEY:-}
AWS_SECRET_ACCESS_KEY=${GCS_SECRET_KEY:-}
AWS_REGION=auto
AWS_S3_UPLOAD_BUCKET_URL=https://storage.googleapis.com
AWS_S3_FORCE_PATH_STYLE=true

# Authentication (Slack)
SLACK_CLIENT_ID=${SLACK_CLIENT_ID:-}
SLACK_CLIENT_SECRET=${SLACK_CLIENT_SECRET:-}

# Shlink
SHLINK_DB_PASSWORD=${SHLINK_DB_PASSWORD}

# Moodle
MOODLE_DB_PASSWORD=${MOODLE_DB_PASSWORD}
MOODLE_ADMIN_PASSWORD=${MOODLE_ADMIN_PASSWORD}
MOODLE_ADMIN_EMAIL=${MOODLE_ADMIN_EMAIL}
MOODLE_WEBHOOK_SECRET=${MOODLE_WEBHOOK_SECRET}

# GRIT
GRIT_API_URL=${GRIT_API_URL}
GRIT_API_KEY=${GRIT_API_KEY}
ENV

# Set proper permissions
chmod 600 .env

# Pull images
log "Pulling Docker images..."
docker compose pull

# Start services
log "Starting services..."
docker compose up -d --build

# Wait for services to be healthy
log "Waiting for services to start..."
sleep 30

# Check status
docker compose ps

# Generate Shlink API key
log "Generating Shlink API key..."
docker compose exec -T shlink shlink api-key:generate

log "Setup complete! Outline should be available at https://${DOMAIN}"
log "Shlink web client at https://links.makenashville.org"
log "Note: DNS must point to this server's external IP for HTTPS to work"
