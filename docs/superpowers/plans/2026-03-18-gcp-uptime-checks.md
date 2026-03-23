# GCP Uptime Checks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GCP Cloud Monitoring uptime checks for 5 Make Nashville services with Slack alerting on downtime.

**Architecture:** A standalone idempotent shell script (`deploy/monitoring.sh`) that uses `gcloud` CLI and Cloud Monitoring REST API to create uptime checks, a Slack notification channel, and per-check alert policies. Follows the same patterns as `deploy/gcloud-setup.sh`.

**Tech Stack:** Bash, gcloud CLI, GCP Cloud Monitoring REST API, curl, jq

**Spec:** `docs/superpowers/specs/2026-03-18-gcp-uptime-checks-design.md`

---

### Task 1: Add HOME_ASSISTANT_URL to config templates

**Files:**
- Modify: `.env.production.example` (insert before Secrets section)

- [ ] **Step 1: Add HOME_ASSISTANT_URL to .env.production.example**

Add after the Slack Notifications section (after `SLACK_WEBHOOK_URL=`, before the Secrets section):

```
# ===================
# Uptime Monitoring (optional)
# ===================
# Home Assistant URL for uptime monitoring
HOME_ASSISTANT_URL=
```

- [ ] **Step 2: Commit**

```bash
git add .env.production.example
git commit -m "Add HOME_ASSISTANT_URL to env example for uptime monitoring"
```

---

### Task 2: Create deploy/monitoring.sh — scaffold and config loading

**Files:**
- Create: `deploy/monitoring.sh`

- [ ] **Step 1: Create the script with config loading and validation**

```bash
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

if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    echo "ERROR: SLACK_WEBHOOK_URL is required for uptime monitoring"
    echo "Alerting without a webhook is pointless — set SLACK_WEBHOOK_URL in .env.production"
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
CHECK_NAMES=(uptime-wiki uptime-grithub uptime-members uptime-website)
CHECK_URLS=("https://wiki.makenashville.org" "https://makenashville.grithub.app/" "https://members.makenashville.org/" "https://makenashville.org")

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
```

- [ ] **Step 2: Make executable**

```bash
chmod +x deploy/monitoring.sh
```

- [ ] **Step 3: Verify script loads and validates**

Run: `bash -n deploy/monitoring.sh`
Expected: no syntax errors (exit 0)

- [ ] **Step 4: Commit**

```bash
git add deploy/monitoring.sh
git commit -m "Add monitoring script scaffold with config loading"
```

---

### Task 3: Add Slack notification channel creation

**Files:**
- Modify: `deploy/monitoring.sh`

- [ ] **Step 1: Add notification channel creation**

Append to `deploy/monitoring.sh`:

```bash
# ============================================
# Create Slack notification channel (if not exists)
# ============================================
echo "Checking for existing Slack notification channel..."

CHANNELS_RESPONSE=$(curl -s \
    -H "$AUTH_HEADER" \
    "$MONITORING_API/notificationChannels" \
    || { echo "ERROR: Failed to list notification channels"; exit 1; })

EXISTING_CHANNEL=$(echo "$CHANNELS_RESPONSE" \
    | jq -r '.notificationChannels[]? | select(.type == "webhook_tokenauth" and .labels.url == "'"$SLACK_WEBHOOK_URL"'") | .name' \
    | head -n1)

if [[ -n "$EXISTING_CHANNEL" ]]; then
    echo "Slack notification channel already exists: $EXISTING_CHANNEL"
    CHANNEL_NAME="$EXISTING_CHANNEL"
else
    echo "Creating Slack notification channel..."
    CHANNEL_RESPONSE=$(curl -s \
        -X POST \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        "$MONITORING_API/notificationChannels" \
        -d '{
            "type": "webhook_tokenauth",
            "displayName": "Make Nashville Slack",
            "labels": {
                "url": "'"$SLACK_WEBHOOK_URL"'"
            }
        }' || { echo "ERROR: Failed to create notification channel"; exit 1; })
    CHANNEL_NAME=$(echo "$CHANNEL_RESPONSE" | jq -r '.name')
    if [[ -z "$CHANNEL_NAME" || "$CHANNEL_NAME" == "null" ]]; then
        echo "ERROR: Failed to create notification channel"
        echo "$CHANNEL_RESPONSE" | jq .
        exit 1
    fi
    echo "Created notification channel: $CHANNEL_NAME"
fi
```

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n deploy/monitoring.sh`
Expected: exit 0

- [ ] **Step 3: Commit**

```bash
git add deploy/monitoring.sh
git commit -m "Add Slack notification channel creation to monitoring script"
```

---

### Task 4: Add uptime check creation

**Files:**
- Modify: `deploy/monitoring.sh`

- [ ] **Step 1: Add uptime check creation loop**

Append to `deploy/monitoring.sh`:

```bash
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
```

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n deploy/monitoring.sh`
Expected: exit 0

- [ ] **Step 3: Commit**

```bash
git add deploy/monitoring.sh
git commit -m "Add uptime check creation to monitoring script"
```

---

### Task 5: Add alert policy creation

**Files:**
- Modify: `deploy/monitoring.sh`

- [ ] **Step 1: Add per-check alert policy creation**

Append to `deploy/monitoring.sh`:

```bash
# ============================================
# Create alert policies (one per check)
# ============================================
echo ""
echo "Setting up alert policies..."

POLICIES_RESPONSE=$(curl -s \
    -H "$AUTH_HEADER" \
    "$MONITORING_API/alertPolicies" \
    || { echo "ERROR: Failed to list alert policies"; exit 1; })

EXISTING_POLICIES=$(echo "$POLICIES_RESPONSE" | jq -r '.alertPolicies[]?.displayName' 2>/dev/null || echo "")

# Get uptime check IDs for linking to alert policies
UPTIME_CONFIGS=$(curl -s \
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
    POLICY_RESPONSE=$(curl -s \
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
```

- [ ] **Step 2: Verify no syntax errors**

Run: `bash -n deploy/monitoring.sh`
Expected: exit 0

- [ ] **Step 3: Commit**

```bash
git add deploy/monitoring.sh
git commit -m "Add alert policy creation to monitoring script"
```

---

### Task 6: Test the script end-to-end

- [ ] **Step 1: Do a dry-run review of the full script**

Run: `cat deploy/monitoring.sh` and review the complete script for correctness.

- [ ] **Step 2: Run the script**

Run: `./deploy/monitoring.sh`

Expected output:
- Cloud Monitoring API enabled
- Slack notification channel created (or found existing)
- 4-5 uptime checks created (depends on HOME_ASSISTANT_URL)
- 4-5 alert policies created (one per check)
- Console link printed

- [ ] **Step 3: Verify in GCP Console**

Visit: `https://console.cloud.google.com/monitoring/uptime?project=YOUR_PROJECT_ID`
Confirm all uptime checks appear and are running.

- [ ] **Step 4: Commit any fixes from testing**

```bash
git add deploy/monitoring.sh
git commit -m "Fix monitoring script issues found during testing"
```
