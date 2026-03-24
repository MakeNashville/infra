#!/bin/bash
set -euo pipefail

# GCP Uptime Check Setup for Make Nashville Services
# Idempotent — safe to re-run. Creates resources if missing, skips if they exist.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env.production"

# ============================================
# Check dependencies
# ============================================
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed"; exit 1; }

# ============================================
# Load configuration
# ============================================
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env.production not found"
    echo "Copy .env.production.example to .env.production and fill in your values"
    exit 1
fi

echo "Loading configuration from .env.production..."
set -a
source "$ENV_FILE"
set +a

# ============================================
# Validate required fields
# ============================================
if [[ -z "${PROJECT_ID:-}" ]]; then
    echo "ERROR: PROJECT_ID is required in .env.production"
    exit 1
fi

gcloud config set project "$PROJECT_ID"

# ============================================
# Enable Cloud Monitoring API
# ============================================
echo "Enabling Cloud Monitoring API..."
gcloud services enable monitoring.googleapis.com

# ============================================
# Define checks (ordered arrays for deterministic iteration)
# ============================================
CHECK_NAMES=(uptime-wiki uptime-grithub uptime-members uptime-website uptime-learn)
CHECK_URLS=("https://wiki.makenashville.org" "https://makenashville.grithub.app/" "https://members.makenashville.org/" "https://makenashville.org" "https://learn.makenashville.org/login/index.php")

if [[ -n "${HOME_ASSISTANT_URL:-}" ]]; then
    CHECK_NAMES+=(uptime-homeassistant)
    CHECK_URLS+=("$HOME_ASSISTANT_URL")
else
    echo "HOME_ASSISTANT_URL not set — skipping Home Assistant uptime check"
fi

AUTH_HEADER="Authorization: Bearer $(gcloud auth print-access-token)"
MONITORING_API="https://monitoring.googleapis.com/v3/projects/$PROJECT_ID"

echo ""
echo "============================================"
echo "Make Nashville Uptime Check Setup"
echo "============================================"
echo "Project: $PROJECT_ID"
echo "Checks: ${CHECK_NAMES[*]}"
echo ""

# ============================================
# Find Slack notification channel
# ============================================
echo "Looking for Slack notification channel..."

CHANNELS_RESPONSE=$(curl -s --fail-with-body \
    -H "$AUTH_HEADER" \
    "$MONITORING_API/notificationChannels" \
    || { echo "ERROR: Failed to list notification channels"; exit 1; })

CHANNEL_NAME=$(echo "$CHANNELS_RESPONSE" \
    | jq -r '.notificationChannels[]? | select(.type == "slack") | .name' \
    | head -n1)

if [[ -z "$CHANNEL_NAME" ]]; then
    echo "ERROR: No Slack notification channel found"
    echo ""
    echo "Set one up in the GCP Console:"
    echo "  1. Go to: https://console.cloud.google.com/monitoring/alerting/notifications?project=$PROJECT_ID"
    echo "  2. Click 'Edit' next to Slack"
    echo "  3. Click 'Add Slack Channel' and authorize"
    echo "  4. Re-run this script"
    exit 1
fi

echo "Found Slack notification channel: $CHANNEL_NAME"

# ============================================
# Create uptime checks
# ============================================
EXISTING_CHECKS=$(gcloud monitoring uptime list-configs --format="value(displayName)" 2>/dev/null || echo "")

for i in "${!CHECK_NAMES[@]}"; do
    CHECK_NAME="${CHECK_NAMES[$i]}"
    CHECK_URL="${CHECK_URLS[$i]}"

    if echo "$EXISTING_CHECKS" | grep -q "^${CHECK_NAME}$"; then
        echo "Uptime check '$CHECK_NAME' already exists — skipping"
        continue
    fi

    # Parse host and path from URL
    CHECK_HOST=$(echo "$CHECK_URL" | sed -E 's|https?://([^/]+).*|\1|')
    CHECK_PATH=$(echo "$CHECK_URL" | sed -E 's|https?://[^/]+||')
    CHECK_PATH="${CHECK_PATH:-/}"

    echo "Creating uptime check '$CHECK_NAME' for $CHECK_URL..."
    gcloud monitoring uptime create "$CHECK_NAME" \
        --resource-type=uptime-url \
        --resource-labels=host="$CHECK_HOST",project_id="$PROJECT_ID" \
        --path="$CHECK_PATH" \
        --protocol=https \
        --period=10 \
        --timeout=10 \
        --regions=usa-iowa,usa-oregon,usa-virginia \
        --validate-ssl=true

    echo "Created uptime check: $CHECK_NAME"
done

# ============================================
# Create alert policies (one per check)
# ============================================
echo ""
echo "Setting up alert policies..."

POLICIES_RESPONSE=$(curl -s --fail-with-body \
    -H "$AUTH_HEADER" \
    "$MONITORING_API/alertPolicies" \
    || { echo "ERROR: Failed to list alert policies"; exit 1; })

EXISTING_POLICIES=$(echo "$POLICIES_RESPONSE" | jq -r '.alertPolicies[]?.displayName' 2>/dev/null || echo "")

# Get uptime check IDs for linking to alert policies
UPTIME_CONFIGS=$(curl -s --fail-with-body \
    -H "$AUTH_HEADER" \
    "$MONITORING_API/uptimeCheckConfigs" \
    || { echo "ERROR: Failed to list uptime configs"; exit 1; })

for i in "${!CHECK_NAMES[@]}"; do
    CHECK_NAME="${CHECK_NAMES[$i]}"
    ALERT_NAME="uptime-alert-${CHECK_NAME#uptime-}"

    if echo "$EXISTING_POLICIES" | grep -q "^${ALERT_NAME}$"; then
        echo "Alert policy '$ALERT_NAME' already exists — skipping"
        continue
    fi

    # Find the uptime check ID by display name
    CHECK_ID=$(echo "$UPTIME_CONFIGS" \
        | jq -r '.uptimeCheckConfigs[]? | select(.displayName == "'"$CHECK_NAME"'") | .name' \
        | sed 's|.*/||')

    if [[ -z "$CHECK_ID" ]]; then
        echo "WARNING: Could not find uptime check ID for '$CHECK_NAME' — skipping alert policy"
        continue
    fi

    echo "Creating alert policy '$ALERT_NAME'..."
    POLICY_RESPONSE=$(curl -s --fail-with-body \
        -X POST \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        "$MONITORING_API/alertPolicies" \
        -d '{
            "displayName": "'"$ALERT_NAME"'",
            "combiner": "OR",
            "conditions": [{
                "displayName": "'"$CHECK_NAME"' failure",
                "conditionThreshold": {
                    "filter": "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"'"$CHECK_ID"'\"",
                    "comparison": "COMPARISON_GT",
                    "thresholdValue": 1,
                    "duration": "600s",
                    "aggregations": [{
                        "alignmentPeriod": "600s",
                        "perSeriesAligner": "ALIGN_NEXT_OLDER",
                        "crossSeriesReducer": "REDUCE_COUNT_FALSE",
                        "groupByFields": ["resource.label.host"]
                    }],
                    "trigger": {
                        "count": 1
                    }
                }
            }],
            "notificationChannels": ["'"$CHANNEL_NAME"'"],
            "alertStrategy": {
                "autoClose": "604800s"
            }
        }' || { echo "ERROR: Failed to create alert policy '$ALERT_NAME'"; exit 1; })

    POLICY_NAME=$(echo "$POLICY_RESPONSE" | jq -r '.name')
    if [[ -z "$POLICY_NAME" || "$POLICY_NAME" == "null" ]]; then
        echo "ERROR: Failed to create alert policy '$ALERT_NAME'"
        echo "$POLICY_RESPONSE" | jq .
        exit 1
    fi

    echo "Created alert policy: $ALERT_NAME"
done

echo ""
echo "============================================"
echo "Uptime monitoring setup complete!"
echo "============================================"
echo ""
echo "Checks created for:"
for i in "${!CHECK_NAMES[@]}"; do
    echo "  ${CHECK_NAMES[$i]} → ${CHECK_URLS[$i]}"
done
echo ""
echo "View in console: https://console.cloud.google.com/monitoring/uptime?project=$PROJECT_ID"
