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
