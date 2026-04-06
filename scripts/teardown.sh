#!/usr/bin/env bash
# =============================================================================
# Steam Pipeline — Teardown script
# =============================================================================
# Destroys all GCP resources (Terraform) and stops Docker containers.
# WARNING: This deletes your GCS data and BigQuery tables.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

echo ""
warn "This will DELETE all GCP resources (GCS buckets, BigQuery dataset, service account)."
warn "Your Kaggle credentials and .env file will NOT be deleted."
echo ""
read -rp "Type 'yes' to confirm: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
info "Stopping Docker containers..."
docker compose down -v --remove-orphans 2>/dev/null || true
success "Docker stopped"

echo ""
info "Destroying GCP resources with Terraform..."

if [ -f ".env" ]; then
    set -a; source .env; set +a
fi

cd terraform
terraform destroy \
    -input=false \
    -auto-approve \
    -var="project_id=${GCP_PROJECT_ID}" \
    -var="bucket_name=${GCS_BUCKET}" \
    -var="bq_dataset=${BQ_DATASET}" \
    -var="gcp_region=${GCP_REGION}" \
    -var="gcp_location=${GCP_LOCATION}"

cd "$ROOT_DIR"

info "Removing local service account key..."
rm -f keys/sa-key.json
success "keys/sa-key.json deleted"

echo ""
success "Teardown complete. All GCP resources destroyed."
echo ""
