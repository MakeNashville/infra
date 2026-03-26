# Zero-Downtime Blue-Green Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate full-stack downtime during deploys by switching to per-service blue-green deployments with health-gated traffic swaps, backed by a CI pipeline that tests and builds before anything touches the VM.

**Architecture:** A new `deploy/deploy.sh` script detects which services changed (via config hashing), spins up new containers alongside old ones using a secondary Compose project, health-checks them, swaps Caddy's upstream via config reload, then tears down the old containers. CI builds and pushes the Moodle image to ghcr.io, runs tests and validation before deploy, and runs smoke tests after.

**Tech Stack:** Docker Compose, Caddy (admin reload), GitHub Actions, GitHub Container Registry (ghcr.io), Bash

**Spec:** `docs/superpowers/specs/2026-03-25-zero-downtime-deploy-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `deploy/deploy.sh` | New. Core blue-green deploy logic: change detection, blue project generation, health-check waiting, Caddy swap, rollback. |
| `deploy/smoke-test.sh` | New. Post-deploy health endpoint validation. Run from CI or manually. |
| `deploy/update-server.sh` | Modify. Replace `docker compose down && up` block (lines 504-507) with call to `deploy.sh`. Keep everything else (metadata fetch, config generation, DB provisioning, backup script, Shlink API key check). |
| `.github/workflows/deploy.yml` | Modify. Add test, validate, build+push, smoke-test stages around the existing deploy step. |
| `docker-compose.yml` | Modify. Change Moodle from `build:` to `image:` referencing ghcr.io. |

---

## Task 1: Create `deploy/deploy.sh` — Change Detection

The foundation: detect which services actually changed since the last deploy.

**Files:**
- Create: `deploy/deploy.sh`

- [ ] **Step 1: Create the deploy script skeleton with change detection**

```bash
#!/bin/bash
set -euo pipefail

cd /opt/outline

# Services eligible for blue-green deploy
BLUE_GREEN_SERVICES=(outline shlink shlink-web oauth2-proxy n8n moodle grit-provisioner)
# Services that get a simple restart if changed
EXCLUDED_SERVICES=(postgres redis caddy)

DEPLOY_STATE_FILE="/opt/outline/.deploy-state"

# Compute a hash for a single service from resolved compose config
hash_service() {
    local service="$1"
    sudo docker compose config --format json | python3 -c "
import sys, json, hashlib
config = json.load(sys.stdin)
svc = config.get('services', {}).get('$service', {})
if svc:
    # Remove runtime-only fields that don't affect the container
    svc.pop('container_name', None)
    print(hashlib.sha256(json.dumps(svc, sort_keys=True).encode()).hexdigest())
else:
    print('MISSING')
"
}

# Compute hashes for all services, compare against saved state
detect_changes() {
    local changed_blue_green=()
    local changed_excluded=()

    # Load previous state
    declare -A prev_hashes
    if [[ -f "$DEPLOY_STATE_FILE" ]]; then
        while IFS='=' read -r svc hash; do
            prev_hashes["$svc"]="$hash"
        done < "$DEPLOY_STATE_FILE"
    else
        echo "No deploy state file found — first run, will do standard deploy"
        return 1
    fi

    # Compare each service
    for svc in "${BLUE_GREEN_SERVICES[@]}"; do
        local current_hash
        current_hash=$(hash_service "$svc")
        if [[ "${prev_hashes[$svc]:-}" != "$current_hash" ]]; then
            changed_blue_green+=("$svc")
        fi
    done

    for svc in "${EXCLUDED_SERVICES[@]}"; do
        local current_hash
        current_hash=$(hash_service "$svc")
        if [[ "${prev_hashes[$svc]:-}" != "$current_hash" ]]; then
            changed_excluded+=("$svc")
        fi
    done

    # Export results
    CHANGED_BLUE_GREEN=("${changed_blue_green[@]+"${changed_blue_green[@]}"}")
    CHANGED_EXCLUDED=("${changed_excluded[@]+"${changed_excluded[@]}"}")

    if [[ ${#CHANGED_BLUE_GREEN[@]} -eq 0 && ${#CHANGED_EXCLUDED[@]} -eq 0 ]]; then
        echo "No services changed — nothing to deploy"
        save_deploy_state
        return 2
    fi

    echo "Changed (blue-green): ${CHANGED_BLUE_GREEN[*]:-none}"
    echo "Changed (excluded): ${CHANGED_EXCLUDED[*]:-none}"
    return 0
}

# Save current hashes for all services
save_deploy_state() {
    local all_services=("${BLUE_GREEN_SERVICES[@]}" "${EXCLUDED_SERVICES[@]}")
    > "$DEPLOY_STATE_FILE"
    for svc in "${all_services[@]}"; do
        echo "${svc}=$(hash_service "$svc")" >> "$DEPLOY_STATE_FILE"
    done
    echo "Deploy state saved to $DEPLOY_STATE_FILE"
}

# Main entrypoint — change detection only for now, more added in later tasks
main() {
    echo "=== Zero-Downtime Deploy ==="

    local detect_result=0
    detect_changes || detect_result=$?

    if [[ $detect_result -eq 1 ]]; then
        echo "First run: performing standard docker compose up"
        sudo docker compose up -d
        save_deploy_state
        exit 0
    fi

    if [[ $detect_result -eq 2 ]]; then
        exit 0
    fi

    # Placeholder: deploy logic added in subsequent tasks
    echo "Deploy logic not yet implemented"
    exit 1
}

main "$@"
```

- [ ] **Step 2: Make the script executable**

Run: `chmod +x deploy/deploy.sh`

- [ ] **Step 3: Verify the script parses without errors**

Run: `bash -n deploy/deploy.sh`
Expected: No output (no syntax errors)

- [ ] **Step 4: Commit**

```
git add deploy/deploy.sh
git commit -m "feat: add deploy.sh with service change detection"
```

---

## Task 2: Add Blue Compose Project Generation to `deploy/deploy.sh`

Generate a `docker-compose.blue.yml` for a single service: same config as primary, but with network alias `<service>-blue`, `depends_on` stripped, attached to the primary network.

**Files:**
- Modify: `deploy/deploy.sh`

- [ ] **Step 1: Add the `generate_blue_compose` function after `save_deploy_state`**

```bash
# Generate a blue compose file for a single service
# Reads the primary docker-compose.yml, extracts the service config,
# strips depends_on, adds network alias, attaches to primary network
generate_blue_compose() {
    local service="$1"
    local blue_file="/opt/outline/docker-compose.blue.yml"
    local primary_network="outline_default"

    sudo docker compose config --format json | python3 -c "
import sys, json

config = json.load(sys.stdin)
service_name = '$service'
primary_network = '$primary_network'

svc = config['services'][service_name]

# Strip depends_on — dependencies are in the primary project
svc.pop('depends_on', None)

# Add network alias so Caddy can reach it as <service>-blue
svc['networks'] = {
    'default': {
        'aliases': ['${service_name}-blue']
    }
}

blue_config = {
    'services': {service_name: svc},
    'networks': {
        'default': {
            'external': True,
            'name': primary_network
        }
    }
}

# Preserve volumes if referenced
volumes = {}
for vol_mount in svc.get('volumes', []):
    if isinstance(vol_mount, dict):
        vol_name = vol_mount.get('source', '')
    else:
        vol_name = vol_mount.split(':')[0]
    # Named volumes (not paths) need to be declared
    if vol_name and not vol_name.startswith('/') and not vol_name.startswith('.'):
        volumes[vol_name] = {'external': True}

if volumes:
    blue_config['volumes'] = volumes

print(json.dumps(blue_config, indent=2))
" | sudo tee "$blue_file" > /dev/null

    echo "$blue_file"
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n deploy/deploy.sh`
Expected: No output

- [ ] **Step 3: Commit**

```
git add deploy/deploy.sh
git commit -m "feat: add blue compose project generation to deploy.sh"
```

---

## Task 3: Add Health Check Waiting to `deploy/deploy.sh`

Read each service's health check config to compute the correct timeout, then poll Docker until healthy or timed out.

**Files:**
- Modify: `deploy/deploy.sh`

- [ ] **Step 1: Add the `get_health_timeout` and `wait_for_healthy` functions after `generate_blue_compose`**

```bash
# Compute health check timeout from service config:
# timeout = start_period + (retries × interval)
# Falls back to 120s if health check config is missing
get_health_timeout() {
    local service="$1"
    sudo docker compose config --format json | python3 -c "
import sys, json, re

def parse_duration(val):
    if isinstance(val, (int, float)):
        # Already in a numeric form (nanoseconds from compose config)
        return val / 1e9
    val = str(val)
    m = re.match(r'(?:(\d+)m)?(?:(\d+)s)?', val)
    if m:
        mins = int(m.group(1) or 0)
        secs = int(m.group(2) or 0)
        return mins * 60 + secs
    return 120

config = json.load(sys.stdin)
svc = config.get('services', {}).get('$service', {})
hc = svc.get('healthcheck', {})

start_period = parse_duration(hc.get('start_period', 0))
interval = parse_duration(hc.get('interval', '5s'))
retries = int(hc.get('retries', 5))

timeout = start_period + (retries * interval)
print(int(max(timeout, 60)))  # minimum 60s
"
}

# Wait for a container to become healthy
# Args: project_name service_name timeout_seconds
wait_for_healthy() {
    local project="$1"
    local service="$2"
    local timeout="$3"
    local elapsed=0
    local interval=5

    echo "Waiting up to ${timeout}s for ${service} to become healthy..."

    while [[ $elapsed -lt $timeout ]]; do
        local health
        health=$(sudo docker compose -p "$project" ps --format json "$service" 2>/dev/null \
            | python3 -c "
import sys, json
for line in sys.stdin:
    data = json.loads(line)
    print(data.get('Health', data.get('Status', 'unknown')))
    break
" 2>/dev/null || echo "unknown")

        if [[ "$health" == *"healthy"* ]]; then
            echo "${service} is healthy after ${elapsed}s"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo "ERROR: ${service} failed to become healthy within ${timeout}s"
    return 1
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n deploy/deploy.sh`
Expected: No output

- [ ] **Step 3: Commit**

```
git add deploy/deploy.sh
git commit -m "feat: add health check timeout calculation and wait logic"
```

---

## Task 4: Add Caddy Swap Logic to `deploy/deploy.sh`

Functions to rewrite the Caddyfile upstreams (global find-and-replace for a service) and reload Caddy.

**Files:**
- Modify: `deploy/deploy.sh`

- [ ] **Step 1: Add the service-to-port mapping and Caddy swap functions after `wait_for_healthy`**

```bash
# Map services to their internal ports (as referenced in Caddyfile)
declare -A SERVICE_PORTS=(
    [outline]=3000
    [shlink]=8080
    [shlink-web]=8080
    [oauth2-proxy]=4180
    [n8n]=5678
    [moodle]=80
)

# Swap Caddyfile upstreams from <service>:<port> to <service>-blue:<port>
swap_caddy_to_blue() {
    local service="$1"
    local port="${SERVICE_PORTS[$service]:-}"

    if [[ -z "$port" ]]; then
        echo "No Caddy upstream for ${service} — skipping Caddy swap"
        return 0
    fi

    echo "Swapping Caddy upstream: ${service}:${port} → ${service}-blue:${port}"
    sudo sed -i "s/${service}:${port}/${service}-blue:${port}/g" /opt/outline/Caddyfile
    reload_caddy
}

# Swap Caddyfile upstreams back from <service>-blue:<port> to <service>:<port>
swap_caddy_to_primary() {
    local service="$1"
    local port="${SERVICE_PORTS[$service]:-}"

    if [[ -z "$port" ]]; then
        return 0
    fi

    echo "Swapping Caddy upstream: ${service}-blue:${port} → ${service}:${port}"
    sudo sed -i "s/${service}-blue:${port}/${service}:${port}/g" /opt/outline/Caddyfile
    reload_caddy
}

# Reload Caddy config gracefully (no dropped connections)
reload_caddy() {
    local caddy_container
    caddy_container=$(sudo docker compose ps -q caddy)
    if [[ -n "$caddy_container" ]]; then
        sudo docker exec "$caddy_container" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
        echo "Caddy reloaded"
    else
        echo "WARNING: Caddy container not found — cannot reload"
        return 1
    fi
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n deploy/deploy.sh`
Expected: No output

- [ ] **Step 3: Commit**

```
git add deploy/deploy.sh
git commit -m "feat: add Caddy upstream swap and reload functions"
```

---

## Task 5: Add Blue-Green Deploy Orchestration to `deploy/deploy.sh`

Wire everything together: for each changed service, run the full blue-green cycle.

**Files:**
- Modify: `deploy/deploy.sh`

- [ ] **Step 1: Add the `deploy_blue_green` and `deploy_excluded` functions, and update `main`**

```bash
# Deploy a single service via blue-green swap
deploy_blue_green_service() {
    local service="$1"
    echo ""
    echo "--- Blue-green deploy: ${service} ---"

    # Step 1: Generate blue compose file
    local blue_file
    blue_file=$(generate_blue_compose "$service")

    # Step 2: Start the new container in the blue project
    echo "Starting ${service} in blue project..."
    sudo docker compose -p blue -f "$blue_file" up -d "$service"

    # Step 3: Wait for health check
    local timeout
    timeout=$(get_health_timeout "$service")
    if ! wait_for_healthy "blue" "$service" "$timeout"; then
        echo "FAILED: ${service} — tearing down blue container, keeping old running"
        sudo docker compose -p blue -f "$blue_file" down 2>/dev/null || true
        sudo rm -f "$blue_file"
        return 1
    fi

    # Step 4: Swap Caddy to blue
    swap_caddy_to_blue "$service"

    # Step 5: Stop old container in primary project
    echo "Stopping old ${service} in primary project..."
    sudo docker compose stop "$service"
    sudo docker compose rm -f "$service"

    # Step 6: Start service in primary project (blue still serves traffic)
    echo "Starting ${service} in primary project..."
    sudo docker compose up -d --no-deps "$service"

    # Step 7: Wait for primary to be healthy
    if ! wait_for_healthy "outline" "$service" "$timeout"; then
        echo "WARNING: ${service} primary container not healthy — blue still serving traffic"
        echo "Manual intervention may be needed"
        sudo rm -f "$blue_file"
        return 1
    fi

    # Step 8: Swap Caddy back to primary
    swap_caddy_to_primary "$service"

    # Step 9: Tear down blue container (no longer receiving traffic)
    echo "Tearing down blue ${service}..."
    sudo docker compose -p blue -f "$blue_file" down 2>/dev/null || true

    sudo rm -f "$blue_file"
    echo "--- ${service} deployed successfully ---"
    return 0
}

# Simple restart for excluded services
deploy_excluded_service() {
    local service="$1"
    echo ""
    echo "--- Restarting excluded service: ${service} ---"
    sudo docker compose up -d --no-deps "$service"
    echo "--- ${service} restarted ---"
}
```

- [ ] **Step 2: Replace the placeholder `main` function with the full orchestration**

Replace the `main` function entirely:

```bash
main() {
    echo "=== Zero-Downtime Deploy ==="
    local failed_services=()

    local detect_result=0
    detect_changes || detect_result=$?

    if [[ $detect_result -eq 1 ]]; then
        echo "First run: performing standard docker compose up"
        sudo docker compose up -d
        save_deploy_state
        exit 0
    fi

    if [[ $detect_result -eq 2 ]]; then
        exit 0
    fi

    # Step 1: Deploy excluded services first (Postgres → Redis → Caddy)
    for svc in postgres redis caddy; do
        for changed in "${CHANGED_EXCLUDED[@]+"${CHANGED_EXCLUDED[@]}"}"; do
            if [[ "$changed" == "$svc" ]]; then
                deploy_excluded_service "$svc"
                break
            fi
        done
    done

    # Step 2: Blue-green deploy changed services sequentially
    for svc in "${CHANGED_BLUE_GREEN[@]+"${CHANGED_BLUE_GREEN[@]}"}"; do
        if ! deploy_blue_green_service "$svc"; then
            failed_services+=("$svc")
        fi
    done

    # Step 3: Save state (even if some services failed — successful ones should be recorded)
    save_deploy_state

    # Report results
    echo ""
    echo "=== Deploy Complete ==="
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        echo "FAILED services: ${failed_services[*]}"
        exit 1
    else
        echo "All services deployed successfully"
        exit 0
    fi
}

main "$@"
```

- [ ] **Step 3: Verify syntax**

Run: `bash -n deploy/deploy.sh`
Expected: No output

- [ ] **Step 4: Commit**

```
git add deploy/deploy.sh
git commit -m "feat: add full blue-green deploy orchestration to deploy.sh"
```

---

## Task 6: Create `deploy/smoke-test.sh`

Post-deploy health endpoint validation script. Accepts a domain argument, checks all public endpoints.

**Files:**
- Create: `deploy/smoke-test.sh`

- [ ] **Step 1: Write the smoke test script**

```bash
#!/bin/bash
set -euo pipefail

# Post-deploy smoke tests — validates all public service health endpoints.
# Usage: ./smoke-test.sh <domain>
# Example: ./smoke-test.sh wiki.makenashville.org
# Can also be run on the VM to include the docker exec check for grit-provisioner.

DOMAIN="${1:?Usage: $0 <domain>}"
RETRIES=3
RETRY_INTERVAL=10
FAILED=()

check_endpoint() {
    local name="$1"
    local url="$2"
    local accept_302="${3:-false}"

    for attempt in $(seq 1 $RETRIES); do
        local http_code
        http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")

        if [[ "$http_code" == "200" ]]; then
            echo "OK: ${name} (${url}) — HTTP ${http_code}"
            return 0
        fi

        if [[ "$accept_302" == "true" && "$http_code" == "302" ]]; then
            echo "OK: ${name} (${url}) — HTTP ${http_code} (redirect, service is up)"
            return 0
        fi

        if [[ $attempt -lt $RETRIES ]]; then
            echo "RETRY: ${name} (${url}) — HTTP ${http_code} (attempt ${attempt}/${RETRIES})"
            sleep "$RETRY_INTERVAL"
        else
            echo "FAIL: ${name} (${url}) — HTTP ${http_code} after ${RETRIES} attempts"
            FAILED+=("$name")
        fi
    done
}

echo "=== Smoke Tests ==="
echo "Domain: ${DOMAIN}"
echo ""

check_endpoint "Outline" "https://${DOMAIN}/_health"
check_endpoint "Shlink" "https://go.makenashville.org/rest/health"
check_endpoint "Shlink-web" "https://links.makenashville.org/" "true"
check_endpoint "OAuth2-proxy" "https://links.makenashville.org/oauth2/ping"
check_endpoint "n8n" "https://automations.makenashville.org/healthz"
check_endpoint "Moodle" "https://learn.makenashville.org/login/index.php"

# GRIT provisioner has no external route — check via docker exec if running on the VM
if command -v docker &> /dev/null; then
    local_grit_check=$(sudo docker compose -f /opt/outline/docker-compose.yml exec -T grit-provisioner wget -qO /dev/null http://127.0.0.1:8000/health 2>&1 && echo "OK" || echo "FAIL")
    if [[ "$local_grit_check" == "OK" ]]; then
        echo "OK: GRIT-provisioner (docker exec health check)"
    else
        echo "FAIL: GRIT-provisioner (docker exec health check)"
        FAILED+=("GRIT-provisioner")
    fi
else
    echo "SKIP: GRIT-provisioner (not running on VM, no docker available)"
fi

echo ""
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "=== SMOKE TESTS FAILED ==="
    echo "Failed services: ${FAILED[*]}"
    exit 1
else
    echo "=== ALL SMOKE TESTS PASSED ==="
    exit 0
fi
```

- [ ] **Step 2: Make executable**

Run: `chmod +x deploy/smoke-test.sh`

- [ ] **Step 3: Verify syntax**

Run: `bash -n deploy/smoke-test.sh`
Expected: No output

- [ ] **Step 4: Commit**

```
git add deploy/smoke-test.sh
git commit -m "feat: add post-deploy smoke test script"
```

---

## Task 7: Modify `deploy/update-server.sh` — Replace Down/Up With `deploy.sh`

Remove the `docker compose down && up` block and replace it with a call to `deploy.sh`.

**Files:**
- Modify: `deploy/update-server.sh:504-507`

- [ ] **Step 1: Replace the restart block**

Replace lines 504-507:
```bash
# Restart services to pick up new config
echo "Restarting services..."
sudo docker compose down --remove-orphans
sudo docker compose up -d --build
```

With:
```bash
# Deploy services (blue-green for changed services, simple restart for excluded)
echo "Deploying services..."
sudo bash /opt/outline/deploy.sh
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n deploy/update-server.sh`
Expected: No output

- [ ] **Step 3: Commit**

```
git add deploy/update-server.sh
git commit -m "feat: replace docker compose down/up with blue-green deploy.sh"
```

---

## Task 8: Modify `docker-compose.yml` — Moodle Image From ghcr.io

Change Moodle from `build:` to `image:` so both primary and blue Compose projects pull the pre-built image. The image tag will be passed via environment variable so CI can set it per deploy.

**Files:**
- Modify: `docker-compose.yml:136`

- [ ] **Step 1: Replace Moodle's `build:` with `image:`**

Replace:
```yaml
  moodle:
    build: ./deploy/moodle
```

With:
```yaml
  moodle:
    image: ghcr.io/makenashville/moodle:${MOODLE_IMAGE_TAG:-latest}
```

- [ ] **Step 2: Update `update-server.sh`'s Moodle heredoc block to match**

In `update-server.sh`, in the docker-compose.yml heredoc (around line 359), replace:
```yaml
  moodle:
    build: ./moodle-docker
```

With:
```yaml
  moodle:
    image: ghcr.io/makenashville/moodle:${MOODLE_IMAGE_TAG:-latest}
```

Also add a line near the top of `update-server.sh` (after the existing `get_metadata` calls, around line 37) to fetch the image tag:
```bash
MOODLE_IMAGE_TAG=$(get_metadata "moodle-image-tag")
```

And add to the `.env` heredoc (around line 215):
```bash
MOODLE_IMAGE_TAG=${MOODLE_IMAGE_TAG}
```

- [ ] **Step 3: Verify syntax of both files**

Run: `bash -n deploy/update-server.sh && docker compose config --quiet`
Expected: No errors

- [ ] **Step 4: Commit**

```
git add docker-compose.yml deploy/update-server.sh
git commit -m "feat: switch Moodle from build to ghcr.io image reference"
```

---

## Task 9: Add Healthcheck to `oauth2-proxy`

`oauth2-proxy` is in the blue-green list but has no healthcheck. Without one, `wait_for_healthy` will always time out and fail. Add a healthcheck to all three places where `oauth2-proxy` is defined.

**Files:**
- Modify: `docker-compose.yml:85-99`
- Modify: `deploy/update-server.sh` (oauth2-proxy block in heredoc, around line 308)
- Modify: `deploy/startup.sh` (oauth2-proxy block in heredoc)

- [ ] **Step 1: Add healthcheck to `docker-compose.yml`**

After the `OAUTH2_PROXY_REVERSE_PROXY=true` line in the oauth2-proxy service, add:

```yaml
    healthcheck:
      test: ["CMD-SHELL", "wget -qO /dev/null http://localhost:4180/ping || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 5
```

- [ ] **Step 2: Add the same healthcheck to `update-server.sh`'s oauth2-proxy heredoc block**

Same healthcheck config, in the docker-compose.yml heredoc inside `update-server.sh`.

- [ ] **Step 3: Add the same healthcheck to `startup.sh`'s oauth2-proxy heredoc block**

Same healthcheck config, in the docker-compose.yml heredoc inside `startup.sh`.

- [ ] **Step 4: Verify syntax**

Run: `bash -n deploy/update-server.sh && bash -n deploy/startup.sh && docker compose config --quiet`
Expected: No errors

- [ ] **Step 5: Commit**

```
git add docker-compose.yml deploy/update-server.sh deploy/startup.sh
git commit -m "feat: add healthcheck to oauth2-proxy for blue-green deploy support"
```

---

## Task 10: Modify `.github/workflows/deploy.yml` — Add CI Pipeline Stages

> **Note:** Tasks 7-10 must be deployed together atomically as a single PR, since `update-server.sh` calls `deploy.sh` which must exist on the VM.

Add test, validate, build+push, and smoke test stages to the GitHub Actions workflow.

**Files:**
- Modify: `.github/workflows/deploy.yml`

- [ ] **Step 1: Add `packages: write` permission for ghcr.io push**

Add to the `permissions` block:
```yaml
permissions:
  contents: read
  id-token: write
  packages: write
```

- [ ] **Step 2: Add a `test` job before the `deploy` job**

Add this job before the existing `deploy` job:

```yaml
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Run grit-provisioner tests
        run: python deploy/grit-provisioner/server_test.py -v

      - name: Validate docker-compose config
        run: docker compose config --quiet
```

- [ ] **Step 3: Add a `build` job that builds and pushes Moodle to ghcr.io**

```yaml
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push Moodle image
        id: meta
        run: |
          TAG="ghcr.io/makenashville/moodle:sha-${GITHUB_SHA::8}"
          docker build -t "$TAG" -t "ghcr.io/makenashville/moodle:latest" deploy/moodle/
          docker push "$TAG"
          docker push "ghcr.io/makenashville/moodle:latest"
```

- [ ] **Step 4: Update the `deploy` job to depend on `test` and `build`, and pass the image tag**

Add `needs: [test, build]` to the deploy job.

In the "Update instance metadata" step, add:
```
moodle-image-tag="sha-${GITHUB_SHA::8}",\
```

In the "Upload files to server" step:
- Add upload of `deploy/deploy.sh` and `deploy/smoke-test.sh`
- Remove the Moodle Dockerfile/entrypoint upload block (no longer needed — image is pre-built in CI)

```yaml
          gcloud compute scp deploy/deploy.sh "$INSTANCE_NAME:~/deploy.sh" --zone="$ZONE"
          gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/deploy.sh /opt/outline/deploy.sh && sudo chmod +x /opt/outline/deploy.sh'

          gcloud compute scp deploy/smoke-test.sh "$INSTANCE_NAME:~/smoke-test.sh" --zone="$ZONE"
          gcloud compute ssh "$INSTANCE_NAME" --zone="$ZONE" --command='sudo mv ~/smoke-test.sh /opt/outline/smoke-test.sh && sudo chmod +x /opt/outline/smoke-test.sh'
```

- [ ] **Step 5: Add a `smoke-test` job after deploy**

```yaml
  smoke-test:
    needs: deploy
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Run smoke tests
        run: bash deploy/smoke-test.sh "${{ secrets.DOMAIN }}"
```

- [ ] **Step 6: Commit**

```
git add .github/workflows/deploy.yml
git commit -m "feat: add test, build, and smoke-test stages to CI pipeline"
```

---

## Task 11: Update `deploy/startup.sh` Moodle Reference

The startup script also has an inline `docker-compose.yml` heredoc that references `build: ./moodle-docker`. This needs to match the new `image:` reference.

**Files:**
- Modify: `deploy/startup.sh`

- [ ] **Step 1: Find and update the Moodle block in `startup.sh`'s docker-compose heredoc**

Find the Moodle service definition in the heredoc and replace `build: ./moodle-docker` with `image: ghcr.io/makenashville/moodle:\${MOODLE_IMAGE_TAG:-latest}`.

Also add `MOODLE_IMAGE_TAG` to the metadata fetch section and `.env` heredoc in `startup.sh`, matching the pattern used in `update-server.sh`.

- [ ] **Step 2: Verify syntax**

Run: `bash -n deploy/startup.sh`
Expected: No output

- [ ] **Step 3: Commit**

```
git add deploy/startup.sh
git commit -m "feat: update startup.sh Moodle reference to ghcr.io image"
```

---

## Task 12: End-to-End Local Validation

Validate the complete deploy pipeline logic locally before pushing.

**Files:**
- All modified files

- [ ] **Step 1: Verify all scripts parse cleanly**

Run:
```bash
bash -n deploy/deploy.sh && \
bash -n deploy/smoke-test.sh && \
bash -n deploy/update-server.sh && \
bash -n deploy/startup.sh && \
echo "All scripts OK"
```
Expected: `All scripts OK`

- [ ] **Step 2: Verify docker-compose.yml is valid**

Run: `docker compose config --quiet`
Expected: No output (valid config). Note: this may warn about missing env vars locally — that's fine as long as it doesn't error on syntax.

- [ ] **Step 3: Verify the GitHub Actions workflow is valid YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml'))"`
Expected: No output (valid YAML)

- [ ] **Step 4: Run grit-provisioner tests to ensure nothing broke**

Run: `cd deploy/grit-provisioner && python3 server_test.py -v`
Expected: All tests pass

- [ ] **Step 5: Commit any fixes if needed, then create final commit**

```
git add -A
git commit -m "chore: end-to-end validation of zero-downtime deploy pipeline"
```
