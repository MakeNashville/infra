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
