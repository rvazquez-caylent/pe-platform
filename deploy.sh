#!/bin/bash
# =============================================================================
# PE Platform — Deployment Script
# Orchestrates Phase 0: infrastructure bootstrap + Bronze seed load
#
# Usage:
#   bash deploy.sh              # full deployment
#   bash deploy.sh --step 3     # run a single step
#   bash deploy.sh --from 4     # resume from a step
#   bash deploy.sh --dry-run    # plan only, no apply
#   bash deploy.sh --destroy    # tear everything down
#   bash deploy.sh --help
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Config ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"
SEEDS_DIR="${SCRIPT_DIR}/seeds"
LOG_FILE="${SCRIPT_DIR}/deploy.log"
REGION="us-west-2"
TF_PLAN_FILE="${TF_DIR}/tfplan"

# ── Argument parsing ──────────────────────────────────────────────
DRY_RUN=false
DESTROY=false
STEP_ONLY=""
FROM_STEP=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true;       shift ;;
    --destroy)  DESTROY=true;       shift ;;
    --step)     STEP_ONLY="$2";     shift 2 ;;
    --from)     FROM_STEP="$2";     shift 2 ;;
    --help|-h)
      echo ""
      echo -e "${BOLD}PE Platform Deployment Script${RESET}"
      echo ""
      echo "  bash deploy.sh              Full deployment (all steps)"
      echo "  bash deploy.sh --step 3     Run only step 3"
      echo "  bash deploy.sh --from 4     Resume from step 4"
      echo "  bash deploy.sh --dry-run    Terraform plan only — no apply"
      echo "  bash deploy.sh --destroy    Destroy all infrastructure"
      echo ""
      echo -e "${BOLD}Steps:${RESET}"
      echo "  1  Check prerequisites"
      echo "  2  Verify AWS credentials"
      echo "  3  Terraform init"
      echo "  4  Terraform plan"
      echo "  5  Terraform apply"
      echo "  6  Generate seed CSVs"
      echo "  7  Upload seeds to S3 Bronze"
      echo "  8  Start Glue crawlers"
      echo "  9  Wait for crawlers & verify"
      echo ""
      exit 0 ;;
    *) echo -e "${RED}Unknown option: $1${RESET}"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $*" >> "${LOG_FILE}"; }

step() {
  local n="$1"; local msg="$2"
  echo -e "\n${BOLD}${BLUE}[$n/9]${RESET} ${BOLD}${msg}${RESET}"
  log "STEP $n: $msg"
}

ok()   { echo -e "  ${GREEN}✔${RESET}  $*"; log "OK: $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; log "WARN: $*"; }
fail() { echo -e "  ${RED}✖${RESET}  $*"; log "FAIL: $*"; }

die() {
  echo -e "\n${RED}${BOLD}FATAL:${RESET} $*"
  echo -e "${YELLOW}See ${LOG_FILE} for details.${RESET}\n"
  log "FATAL: $*"
  exit 1
}

should_run() {
  local n="$1"
  [[ -n "$STEP_ONLY" ]] && [[ "$STEP_ONLY" != "$n" ]] && return 1
  [[ "$n" -lt "$FROM_STEP" ]] && return 1
  return 0
}

tf() { (cd "${TF_DIR}" && terraform "$@" 2>&1 | tee -a "${LOG_FILE}"); }

# ── Banner ────────────────────────────────────────────────────────

echo "" >> "${LOG_FILE}"
echo "======================================================" >> "${LOG_FILE}"
echo "Deployment started: $(date)" >> "${LOG_FILE}"
echo "======================================================" >> "${LOG_FILE}"

echo -e ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║   PE Platform — Deployment Script            ║${RESET}"
echo -e "${BOLD}${CYAN}║   Phase 0: Infrastructure Bootstrap          ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
echo -e "  Region  : ${REGION}"
echo -e "  Mode    : $(${DRY_RUN} && echo 'DRY RUN (plan only)' || echo 'APPLY')"
echo -e "  Log     : ${LOG_FILE}"
echo -e ""

# ── Destroy mode ─────────────────────────────────────────────────

if ${DESTROY}; then
  echo -e "${RED}${BOLD}⚠  DESTROY MODE — this will delete ALL infrastructure${RESET}"
  read -rp "   Type 'destroy' to confirm: " confirm
  [[ "$confirm" != "destroy" ]] && die "Aborted."
  echo -e "${YELLOW}Destroying...${RESET}"
  tf destroy -auto-approve || die "terraform destroy failed"
  echo -e "${GREEN}${BOLD}Infrastructure destroyed.${RESET}"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────
# STEP 1 — Prerequisites
# ─────────────────────────────────────────────────────────────────
if should_run 1; then
  step 1 "Checking prerequisites"

  check_tool() {
    local cmd="$1"; local min_ver="$2"; local label="$3"
    if command -v "$cmd" &>/dev/null; then
      ok "${label}: $(${cmd} --version 2>&1 | head -1)"
    else
      die "${label} not found. Install it and re-run."
    fi
  }

  check_tool aws       "" "AWS CLI"
  check_tool terraform "" "Terraform"
  check_tool node      "" "Node.js"
  check_tool python3   "" "Python 3"

  # Check Terraform version >= 1.7
  TF_VER=$(terraform --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  TF_MAJOR=$(echo "$TF_VER" | cut -d. -f1)
  TF_MINOR=$(echo "$TF_VER" | cut -d. -f2)
  if [[ "$TF_MAJOR" -lt 1 ]] || { [[ "$TF_MAJOR" -eq 1 ]] && [[ "$TF_MINOR" -lt 7 ]]; }; then
    die "Terraform >= 1.7.0 required (found ${TF_VER}). Run: brew upgrade terraform"
  fi
fi

# ─────────────────────────────────────────────────────────────────
# STEP 2 — AWS credentials
# ─────────────────────────────────────────────────────────────────
if should_run 2; then
  step 2 "Verifying AWS credentials"

  IDENTITY=$(aws sts get-caller-identity --output json 2>&1) \
    || die "AWS credentials not configured.\nRun: aws configure\nThen re-run this script."

  ACCOUNT_ID=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
  USER_ARN=$(echo "$IDENTITY"   | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")

  ok "Account ID : ${ACCOUNT_ID}"
  ok "Identity   : ${USER_ARN}"
  ok "Region     : ${REGION}"

  # Persist account ID for later steps
  echo "$ACCOUNT_ID" > "${SCRIPT_DIR}/.account_id"
fi

# Load account ID (needed from step 7 onward even when skipping earlier steps)
if [[ -f "${SCRIPT_DIR}/.account_id" ]]; then
  ACCOUNT_ID=$(cat "${SCRIPT_DIR}/.account_id")
fi

# ─────────────────────────────────────────────────────────────────
# STEP 3 — Terraform init
# ─────────────────────────────────────────────────────────────────
if should_run 3; then
  step 3 "Terraform init"

  if [[ ! -d "${TF_DIR}/.terraform" ]]; then
    tf init || die "terraform init failed"
    ok "Terraform initialized"
  else
    tf init -upgrade || die "terraform init -upgrade failed"
    ok "Terraform providers up to date"
  fi
fi

# ─────────────────────────────────────────────────────────────────
# STEP 4 — Terraform plan
# ─────────────────────────────────────────────────────────────────
if should_run 4; then
  step 4 "Terraform plan"

  tf plan -out="${TF_PLAN_FILE}" \
    -var="region=${REGION}" \
    || die "terraform plan failed"

  RESOURCE_COUNT=$(tf show -json "${TF_PLAN_FILE}" 2>/dev/null \
    | python3 -c "
import sys, json
p = json.load(sys.stdin)
adds = [c for c in p.get('resource_changes', []) if 'create' in c.get('change', {}).get('actions', [])]
print(len(adds))
" 2>/dev/null || echo "?")

  ok "Plan complete — ${RESOURCE_COUNT} resources to create"

  if ${DRY_RUN}; then
    echo -e "\n${YELLOW}${BOLD}DRY RUN: stopping before apply.${RESET}"
    echo -e "Re-run without --dry-run to deploy.\n"
    exit 0
  fi
fi

# ─────────────────────────────────────────────────────────────────
# STEP 5 — Terraform apply
# ─────────────────────────────────────────────────────────────────
if should_run 5; then
  step 5 "Terraform apply"

  if [[ ! -f "${TF_PLAN_FILE}" ]]; then
    warn "No saved plan found — running plan first"
    tf plan -out="${TF_PLAN_FILE}" -var="region=${REGION}" \
      || die "terraform plan failed"
  fi

  tf apply "${TF_PLAN_FILE}" || die "terraform apply failed"
  rm -f "${TF_PLAN_FILE}"

  # Extract outputs
  DATA_LAKE_BUCKET=$(cd "${TF_DIR}" && terraform output -raw data_lake_bucket 2>/dev/null)
  ATHENA_RESULTS_BUCKET=$(cd "${TF_DIR}" && terraform output -raw athena_results_bucket 2>/dev/null)
  ATHENA_WORKGROUP=$(cd "${TF_DIR}" && terraform output -raw athena_workgroup 2>/dev/null)
  GLUE_DB_BRONZE=$(cd "${TF_DIR}" && terraform output -raw glue_database_bronze 2>/dev/null)

  ok "Data lake bucket   : ${DATA_LAKE_BUCKET}"
  ok "Athena results     : ${ATHENA_RESULTS_BUCKET}"
  ok "Athena workgroup   : ${ATHENA_WORKGROUP}"
  ok "Glue Bronze DB     : ${GLUE_DB_BRONZE}"

  # Persist for later steps
  cat > "${SCRIPT_DIR}/.tf_outputs" <<EOF
DATA_LAKE_BUCKET=${DATA_LAKE_BUCKET}
ATHENA_RESULTS_BUCKET=${ATHENA_RESULTS_BUCKET}
ATHENA_WORKGROUP=${ATHENA_WORKGROUP}
GLUE_DB_BRONZE=${GLUE_DB_BRONZE}
EOF
fi

# Load TF outputs (needed when resuming from step 6+)
if [[ -f "${SCRIPT_DIR}/.tf_outputs" ]]; then
  source "${SCRIPT_DIR}/.tf_outputs"
else
  # Try to read live from terraform
  DATA_LAKE_BUCKET=$(cd "${TF_DIR}" && terraform output -raw data_lake_bucket 2>/dev/null) \
    || die "Cannot resolve data lake bucket. Run from step 5: bash deploy.sh --from 5"
  source <(cd "${TF_DIR}" && terraform output | sed 's/ = /=/' | sed 's/"//g')
fi

# ─────────────────────────────────────────────────────────────────
# STEP 6 — Generate seed CSVs
# ─────────────────────────────────────────────────────────────────
if should_run 6; then
  step 6 "Generating seed CSVs from data.js"

  node "${SEEDS_DIR}/generate_seeds.js" >> "${LOG_FILE}" 2>&1 \
    || die "generate_seeds.js failed — check ${LOG_FILE}"

  CSV_COUNT=$(ls "${SEEDS_DIR}/csv/"*.csv 2>/dev/null | wc -l | tr -d ' ')
  ok "${CSV_COUNT} CSV files generated in seeds/csv/"

  for f in "${SEEDS_DIR}/csv/"*.csv; do
    ROWS=$(( $(wc -l < "$f") - 1 ))
    ok "  $(basename $f) — ${ROWS} rows"
  done
fi

# ─────────────────────────────────────────────────────────────────
# STEP 7 — Upload seeds to S3 Bronze
# ─────────────────────────────────────────────────────────────────
if should_run 7; then
  step 7 "Uploading seed CSVs to S3 Bronze layer"

  bash "${SEEDS_DIR}/upload_seeds.sh" "${DATA_LAKE_BUCKET}" \
    >> "${LOG_FILE}" 2>&1 \
    || die "upload_seeds.sh failed — check ${LOG_FILE}"

  ok "All seed files uploaded to s3://${DATA_LAKE_BUCKET}/bronze/"

  # Verify a few files actually landed
  for prefix in "bronze/fund-metrics" "bronze/portfolio-companies" "bronze/cashflows" "bronze/pipeline"; do
    COUNT=$(aws s3 ls "s3://${DATA_LAKE_BUCKET}/${prefix}/" --recursive \
      | grep "\.csv" | wc -l | tr -d ' ')
    ok "  ${prefix}: ${COUNT} CSV file(s)"
  done
fi

# ─────────────────────────────────────────────────────────────────
# STEP 8 — Start Glue crawlers
# ─────────────────────────────────────────────────────────────────
if should_run 8; then
  step 8 "Starting Glue crawlers"

  PREFIX="scp3-dev"

  start_crawler() {
    local name="${PREFIX}-bronze-${1}"
    echo -e "  Starting ${name}..."
    aws glue start-crawler --name "${name}" --region "${REGION}" \
      >> "${LOG_FILE}" 2>&1 \
      && ok "${name} started" \
      || warn "${name} may already be running — skipping"
  }

  start_crawler "companies"
  start_crawler "cashflows"
  start_crawler "pipeline"
  start_crawler "fund"
fi

# ─────────────────────────────────────────────────────────────────
# STEP 9 — Wait for crawlers & verify
# ─────────────────────────────────────────────────────────────────
if should_run 9; then
  step 9 "Waiting for Glue crawlers to complete"

  PREFIX="scp3-dev"
  CRAWLERS=("${PREFIX}-bronze-companies" "${PREFIX}-bronze-cashflows" \
            "${PREFIX}-bronze-pipeline"  "${PREFIX}-bronze-fund")

  MAX_WAIT=300   # 5 minutes
  POLL=10
  ELAPSED=0
  ALL_DONE=false

  while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    ALL_DONE=true
    for crawler in "${CRAWLERS[@]}"; do
      STATUS=$(aws glue get-crawler --name "${crawler}" --region "${REGION}" \
        --query 'Crawler.LastCrawl.Status' --output text 2>/dev/null || echo "UNKNOWN")
      STATE=$(aws glue get-crawler --name "${crawler}" --region "${REGION}" \
        --query 'Crawler.State' --output text 2>/dev/null || echo "UNKNOWN")

      if [[ "$STATE" == "RUNNING" ]]; then
        ALL_DONE=false
        echo -ne "  ⏳  ${crawler}: running (${ELAPSED}s)...\r"
      elif [[ "$STATUS" == "SUCCEEDED" ]]; then
        : # already done
      else
        ALL_DONE=false
        echo -ne "  ⏳  ${crawler}: ${STATE}/${STATUS} (${ELAPSED}s)...\r"
      fi
    done
    ${ALL_DONE} && break
    sleep $POLL
    ELAPSED=$(( ELAPSED + POLL ))
  done

  echo "" # clear the \r line

  if ! ${ALL_DONE}; then
    warn "Some crawlers didn't finish within ${MAX_WAIT}s — check AWS Console"
    warn "You can re-run step 9: bash deploy.sh --step 9"
  fi

  echo ""
  echo -e "  ${BOLD}Crawler results:${RESET}"
  for crawler in "${CRAWLERS[@]}"; do
    STATUS=$(aws glue get-crawler --name "${crawler}" --region "${REGION}" \
      --query 'Crawler.LastCrawl.Status' --output text 2>/dev/null || echo "UNKNOWN")
    TABLES=$(aws glue get-crawler --name "${crawler}" --region "${REGION}" \
      --query 'Crawler.LastCrawl.TablesCreated' --output text 2>/dev/null || echo "0")

    if [[ "$STATUS" == "SUCCEEDED" ]]; then
      ok "${crawler}: SUCCEEDED (${TABLES} tables created)"
    else
      fail "${crawler}: ${STATUS}"
    fi
  done

  # List tables registered in Bronze database
  echo ""
  echo -e "  ${BOLD}Tables registered in Glue Bronze catalog:${RESET}"
  TABLES=$(aws glue get-tables \
    --database-name "${PREFIX}_bronze" \
    --region "${REGION}" \
    --query 'TableList[].Name' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$TABLES" ]]; then
    for t in $TABLES; do ok "  ${t}"; done
  else
    warn "No tables found yet — crawlers may still be running"
  fi
fi

# ─────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║   Phase 0 Complete ✔                         ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Resources deployed:${RESET}"
echo -e "  • S3 data lake      : ${CYAN}s3://${DATA_LAKE_BUCKET:-<bucket>}${RESET}"
echo -e "  • Athena workgroup  : ${CYAN}${ATHENA_WORKGROUP:-scp3-dev-workgroup}${RESET}"
echo -e "  • Glue Bronze DB    : ${CYAN}${GLUE_DB_BRONZE:-scp3_dev_bronze}${RESET}"
echo ""
echo -e "  ${BOLD}Verify in AWS Console:${RESET}"
echo -e "  • S3       : https://s3.console.aws.amazon.com/s3/buckets/${DATA_LAKE_BUCKET:-<bucket>}"
echo -e "  • Athena   : https://${REGION}.console.aws.amazon.com/athena/home?region=${REGION}"
echo -e "  • Glue     : https://${REGION}.console.aws.amazon.com/glue/home?region=${REGION}"
echo ""
echo -e "  ${BOLD}Quick Athena test:${RESET}"
echo -e "  ${CYAN}SELECT * FROM ${GLUE_DB_BRONZE:-scp3_dev_bronze}.portfolio_companies LIMIT 5;${RESET}"
echo ""
echo -e "  ${BOLD}Next:${RESET} Phase 1 — Bronze → Silver → Gold ETL"
echo -e "  See ROADMAP.md for details."
echo ""
echo -e "  Log saved to: ${LOG_FILE}"
echo ""
