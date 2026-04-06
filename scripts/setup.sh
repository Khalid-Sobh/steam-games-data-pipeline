# #!/usr/bin/env bash
# # =============================================================================
# # Steam Pipeline — One-command setup script
# # =============================================================================
# # Usage: bash scripts/setup.sh
# # What it does:
# #   1. Checks prerequisites (Docker, Terraform, gcloud, Python)
# #   2. Copies .env.example → .env if not already present
# #   3. Validates that .env is fully filled in
# #   4. Runs terraform apply to provision all GCP resources
# #   5. Builds and starts Docker containers
# #   6. Waits for Airflow to be healthy
# #   7. Prints next steps
# # =============================================================================

# set -euo pipefail

# # ── Colours ──────────────────────────────────────────────────────────────────
# RED='\033[0;31m'
# GREEN='\033[0;32m'
# YELLOW='\033[1;33m'
# BLUE='\033[0;34m'
# NC='\033[0m'

# info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
# success() { echo -e "${GREEN}[OK]${NC}    $*"; }
# warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
# error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# cd "$ROOT_DIR"

# echo ""
# echo -e "${BLUE}======================================================${NC}"
# echo -e "${BLUE}   Steam Data Pipeline — Setup${NC}"
# echo -e "${BLUE}======================================================${NC}"
# echo ""

# # ── 1. Check prerequisites ────────────────────────────────────────────────────
# info "Checking prerequisites..."

# check_cmd() {
#     if ! command -v "$1" &>/dev/null; then
#         error "$1 is not installed. $2"
#     fi
#     success "$1 found"
# }

# check_cmd docker    "Install Docker Desktop: https://www.docker.com/products/docker-desktop"
# check_cmd terraform "Install Terraform: https://developer.hashicorp.com/terraform/install"
# check_cmd python3   "Install Python 3.11+: https://www.python.org/downloads/"

# # Docker running?
# if ! docker info &>/dev/null; then
#     error "Docker is installed but not running. Please start Docker Desktop."
# fi
# success "Docker is running"

# echo ""

# # ── 2. Set up .env ────────────────────────────────────────────────────────────
# info "Checking .env file..."

# if [ ! -f ".env" ]; then
#     cp .env.example .env
#     warn ".env created from .env.example — please fill in your values now."
#     echo ""
#     echo "  Open .env in your editor and fill in:"
#     echo "    GCP_PROJECT_ID   — your GCP project ID"
#     echo "    GCS_BUCKET       — a globally unique bucket name"
#     echo "    KAGGLE_USERNAME  — your Kaggle username"
#     echo "    KAGGLE_KEY       — your Kaggle API key"
#     echo "    AIRFLOW__CORE__FERNET_KEY — run the command below to generate:"
#     echo ""
#     echo "    python3 -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\""
#     echo ""
#     read -rp "  Press ENTER when .env is ready, or Ctrl+C to exit... "
# fi

# # ── 3. Validate .env values ───────────────────────────────────────────────────
# info "Validating .env..."

# load_env() {
#     set -a
#     # shellcheck disable=SC1091
#     source .env
#     set +a
# }
# load_env

# REQUIRED_VARS=(
#     GCP_PROJECT_ID
#     GCS_BUCKET
#     BQ_DATASET
#     GCP_REGION
#     GCP_LOCATION
#     KAGGLE_USERNAME
#     KAGGLE_KEY
#     AIRFLOW__CORE__FERNET_KEY
# )

# MISSING=()
# for var in "${REQUIRED_VARS[@]}"; do
#     val="${!var:-}"
#     # Chechk if variable is empty or still has placeholder text (e.g. "your_" or "my-")
#     # if [ -z "$val" ] || [[ "$val" == *"your_"* ]] || [[ "$val" == *"my-"* ]] || [[ "$val" == *"my_"* ]]; then
#     #     MISSING+=("$var")
#     # fi
#     # checking only if variable is empty.
#     if [ -z "$val" ]; then
#     MISSING+=("$var")
#     fi
# done

# if [ ${#MISSING[@]} -gt 0 ]; then
#     error "The following variables in .env are not filled in:\n  ${MISSING[*]}\n\n  Edit .env and re-run this script."
# fi
# success ".env looks good"

# echo ""

# # ── 4. Create keys/ directory ────────────────────────────────────────────────
# mkdir -p keys
# info "keys/ directory ready"

# # ── 5. Terraform ─────────────────────────────────────────────────────────────
# echo ""
# info "Running Terraform to provision GCP resources..."
# echo "  Project  : $GCP_PROJECT_ID"
# echo "  Bucket   : $GCS_BUCKET"
# echo "  Region   : $GCP_REGION"
# echo "  BQ       : $BQ_DATASET"
# echo ""

# cd terraform

# terraform init -input=false

# terraform apply \
#     -input=false \
#     -auto-approve \
#     -var="project_id=${GCP_PROJECT_ID}" \
#     -var="bucket_name=${GCS_BUCKET}" \
#     -var="bq_dataset=${BQ_DATASET}" \
#     -var="gcp_region=${GCP_REGION}" \
#     -var="gcp_location=${GCP_LOCATION}"

# cd "$ROOT_DIR"

# if [ ! -f "keys/sa-key.json" ]; then
#     error "Terraform ran but keys/sa-key.json was not created. Check terraform output above."
# fi
# success "GCP resources provisioned. Service account key written to keys/sa-key.json"

# echo ""

# # ── 6. Docker Compose ────────────────────────────────────────────────────────
# info "Building and starting Docker containers..."

# # Generate AIRFLOW_UID
# export AIRFLOW_UID=$(id -u)

# docker compose down --remove-orphans 2>/dev/null || true
# docker compose build --no-cache
# docker compose up airflow-init
# docker compose up -d --remove-orphans

# echo ""
# info "Waiting for Airflow webserver to become healthy (up to 120s)..."

# TIMEOUT=120
# ELAPSED=0
# until curl -sf "http://localhost:8080/health" | grep -q '"healthy"' 2>/dev/null; do
#     sleep 5
#     ELAPSED=$((ELAPSED + 5))
#     echo -n "."
#     if [ $ELAPSED -ge $TIMEOUT ]; then
#         echo ""
#         warn "Airflow took longer than expected. Check logs: docker compose logs airflow-webserver"
#         break
#     fi
# done
# echo ""
# success "Airflow is healthy"

# echo ""

# # ── 7. Done ───────────────────────────────────────────────────────────────────
# echo -e "${GREEN}======================================================${NC}"
# echo -e "${GREEN}   Setup complete!${NC}"
# echo -e "${GREEN}======================================================${NC}"
# echo ""
# echo "  Airflow UI  →  http://localhost:8080"
# echo "  Username    →  ${AIRFLOW_ADMIN_USERNAME:-admin}"
# echo "  Password    →  ${AIRFLOW_ADMIN_PASSWORD:-admin}"
# echo ""
# echo "  Next steps:"
# echo ""
# echo "  1. Open http://localhost:8080"
# echo "  2. Go to DAGs → enable and trigger: steam_01_ingest_to_lake"
# echo "  3. Once it completes, trigger: steam_02_lake_to_warehouse"
# echo "  4. Connect Looker Studio → BigQuery → steam_warehouse"
# echo "     Tile 1: metacritic_by_genre"
# echo "     Tile 2: releases_by_year_and_tier"
# echo ""
# echo "  Both DAGs also run automatically:"
# echo "    steam_01_ingest_to_lake    → daily at 06:00 UTC"
# echo "    steam_02_lake_to_warehouse → daily at 08:00 UTC"
# echo ""
# echo "  To stop:  docker compose down"
# echo "  To reset: docker compose down -v  (deletes Airflow DB)"
# echo ""



#!/usr/bin/env bash
# =============================================================================
# Steam Pipeline — One-command setup script (safe for limited permissions)
# =============================================================================

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo ""
echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}   Steam Data Pipeline — Setup${NC}"
echo -e "${BLUE}======================================================${NC}"
echo ""

# ── 1. Check prerequisites ────────────────────────────────────────────────────
info "Checking prerequisites..."

check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        error "$1 is not installed. $2"
    fi
    success "$1 found"
}

check_cmd docker    "Install Docker Desktop: https://www.docker.com/products/docker-desktop"
check_cmd terraform "Install Terraform: https://developer.hashicorp.com/terraform/install"
check_cmd python3   "Install Python 3.11+: https://www.python.org/downloads/"

# Docker running?
if ! docker info &>/dev/null; then
    error "Docker is installed but not running. Please start Docker Desktop."
fi
success "Docker is running"

echo ""

# ── 2. Set up .env ────────────────────────────────────────────────────────────
info "Checking .env file..."

if [ ! -f ".env" ]; then
    cp .env.example .env
    warn ".env created from .env.example — please fill in your values now."
    echo ""
    read -rp "Press ENTER when .env is ready, or Ctrl+C to exit... "
fi

# ── 3. Load .env ─────────────────────────────────────────────────────────────
info "Loading .env variables..."
set -a
# shellcheck disable=SC1091
source .env
set +a
success ".env loaded"

# ── 4. Create keys/ directory ────────────────────────────────────────────────
mkdir -p keys
info "keys/ directory ready"

# ── 5. Terraform ─────────────────────────────────────────────────────────────
echo ""
info "Running Terraform to provision GCP resources..."
echo "  Project  : $GCP_PROJECT_ID"
echo "  Bucket   : $GCS_BUCKET"
echo "  Region   : $GCP_REGION"
echo "  BQ       : $BQ_DATASET"
echo ""

cd terraform

terraform init -input=false

# Try to apply Terraform; catch IAM errors and continue
set +e
terraform apply \
    -input=false \
    -auto-approve \
    -var="project_id=${GCP_PROJECT_ID}" \
    -var="bucket_name=${GCS_BUCKET}" \
    -var="bq_dataset=${BQ_DATASET}" \
    -var="gcp_region=${GCP_REGION}" \
    -var="gcp_location=${GCP_LOCATION}"

TERRAFORM_EXIT=$?
set -e

if [ $TERRAFORM_EXIT -ne 0 ]; then
    warn "Terraform encountered errors (possibly IAM-related). Skipping IAM role assignment."
fi

cd "$ROOT_DIR"

if [ ! -f "keys/sa-key.json" ]; then
    warn "keys/sa-key.json not found. Terraform may not have created the service account key."
else
    success "Service account key available at keys/sa-key.json"
fi

# ── 6. Docker Compose ────────────────────────────────────────────────────────
info "Building and starting Docker containers..."

# Generate AIRFLOW_UID
export AIRFLOW_UID=$(id -u)

docker compose down --remove-orphans 2>/dev/null || true
docker compose build --no-cache
docker compose up airflow-init
docker compose up -d --remove-orphans

echo ""
info "Waiting for Airflow webserver to become healthy (up to 120s)..."

TIMEOUT=120
ELAPSED=0
until curl -sf "http://localhost:8080/health" | grep -q '"healthy"' 2>/dev/null; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -n "."
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo ""
        warn "Airflow took longer than expected. Check logs: docker compose logs airflow-webserver"
        break
    fi
done
echo ""
success "Airflow is healthy"

# ── 7. Done ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}   Setup complete!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo ""
echo "  Airflow UI  →  http://localhost:8080"
echo "  Username    →  ${AIRFLOW_ADMIN_USERNAME:-admin}"
echo "  Password    →  ${AIRFLOW_ADMIN_PASSWORD:-admin}"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Open http://localhost:8080"
echo "  2. Enable DAGs: steam_01_ingest_to_lake and steam_02_lake_to_warehouse"
echo "  3. Connect Looker Studio → BigQuery → steam_warehouse"
echo ""
echo "  To stop:  docker compose down"
echo "  To reset: docker compose down -v  (deletes Airflow DB)"
info "Unpausing DAGs..."
sleep 10  # give scheduler time to register the DAGs
# make sure to unpause DAGs so they run on schedule (and can be triggered manually)
docker exec steam-dashboard-airflow-scheduler-1 \
    airflow dags unpause steam_01_ingest_to_lake
docker exec steam-dashboard-airflow-scheduler-1 \
    airflow dags unpause steam_02_lake_to_warehouse
success "Both DAGs unpaused and ready"
echo ""