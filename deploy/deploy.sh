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
