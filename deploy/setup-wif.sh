#!/bin/bash
set -euo pipefail

# One-time setup: Workload Identity Federation for GitHub Actions
# Run this once to allow GitHub Actions to authenticate to GCP

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID env var (e.g. export PROJECT_ID=my-gcp-project)}"
REPO="MakeNashville/infra"
POOL_NAME="github-actions-pool"
PROVIDER_NAME="github-oidc"
SA_EMAIL="github-deploy@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Setting up Workload Identity Federation..."
gcloud config set project "$PROJECT_ID"

# Enable required APIs
gcloud services enable iamcredentials.googleapis.com
gcloud services enable iam.googleapis.com

# Create service account for GitHub Actions deploys
gcloud iam service-accounts create github-deploy \
    --display-name="GitHub Actions Deploy" \
    2>/dev/null || echo "Service account already exists"

# Grant permissions to the service account
for ROLE in roles/compute.instanceAdmin.v1 roles/storage.admin roles/compute.osLogin; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$SA_EMAIL" \
        --role="$ROLE" \
        --condition=None \
        2>/dev/null
done

# Create Workload Identity Pool
gcloud iam workload-identity-pools create "$POOL_NAME" \
    --location="global" \
    --display-name="GitHub Actions" \
    2>/dev/null || echo "Pool already exists"

# Create OIDC Provider
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_NAME" \
    --location="global" \
    --workload-identity-pool="$POOL_NAME" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository=='${REPO}'" \
    2>/dev/null || echo "Provider already exists"

# Bind the pool to the service account
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')/locations/global/workloadIdentityPools/${POOL_NAME}/attribute.repository/${REPO}"

# Output values needed for GitHub Secrets
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
echo ""
echo "============================================"
echo "WIF Setup Complete!"
echo "============================================"
echo ""
echo "Add these as GitHub Repository Secrets:"
echo ""
echo "  GCP_PROJECT_ID=$PROJECT_ID"
echo "  GCP_SERVICE_ACCOUNT=$SA_EMAIL"
echo "  GCP_WORKLOAD_IDENTITY_PROVIDER=projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/providers/${PROVIDER_NAME}"
echo ""
