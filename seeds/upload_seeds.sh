#!/bin/bash
# Uploads Bronze-layer seed CSV files to S3
# Usage: bash upload_seeds.sh <DATA_LAKE_BUCKET_NAME>
# Example: bash upload_seeds.sh scp3-dev-data-lake-123456789012

set -euo pipefail

BUCKET="${1:?Usage: bash upload_seeds.sh <DATA_LAKE_BUCKET_NAME>}"
CSV_DIR="$(dirname "$0")/csv"
DATE=$(date +%Y-%m-%d)

echo "🚀  Uploading seed data to s3://${BUCKET}/bronze/"
echo "    Date partition: ${DATE}"
echo ""

upload() {
  local file="$1"
  local s3_path="$2"
  echo "  ↑  $(basename $file)  →  s3://${BUCKET}/${s3_path}"
  aws s3 cp "$file" "s3://${BUCKET}/${s3_path}" \
    --content-type "text/csv" \
    --metadata "source=seed,load_date=${DATE}"
}

upload "${CSV_DIR}/fund_metrics.csv"         "bronze/fund-metrics/load_date=${DATE}/fund_metrics.csv"
upload "${CSV_DIR}/portfolio_companies.csv"  "bronze/portfolio-companies/load_date=${DATE}/portfolio_companies.csv"
upload "${CSV_DIR}/company_revenue.csv"      "bronze/portfolio-companies/load_date=${DATE}/company_revenue.csv"
upload "${CSV_DIR}/company_ebitda.csv"       "bronze/portfolio-companies/load_date=${DATE}/company_ebitda.csv"
upload "${CSV_DIR}/quarterly_cashflows.csv"  "bronze/cashflows/load_date=${DATE}/quarterly_cashflows.csv"
upload "${CSV_DIR}/fund_history.csv"         "bronze/cashflows/load_date=${DATE}/fund_history.csv"
upload "${CSV_DIR}/deal_pipeline.csv"        "bronze/pipeline/load_date=${DATE}/deal_pipeline.csv"
upload "${CSV_DIR}/sector_breakdown.csv"     "bronze/fund-metrics/load_date=${DATE}/sector_breakdown.csv"
upload "${CSV_DIR}/geo_breakdown.csv"        "bronze/fund-metrics/load_date=${DATE}/geo_breakdown.csv"

echo ""
echo "✅  Upload complete."
echo ""
echo "Next step: run the Glue crawlers to register schemas in the Glue catalog:"
echo ""
echo "  aws glue start-crawler --name scp3-dev-bronze-companies  --region us-west-2"
echo "  aws glue start-crawler --name scp3-dev-bronze-cashflows   --region us-west-2"
echo "  aws glue start-crawler --name scp3-dev-bronze-pipeline    --region us-west-2"
echo "  aws glue start-crawler --name scp3-dev-bronze-fund        --region us-west-2"
echo ""
echo "Then check crawler status:"
echo "  aws glue get-crawler --name scp3-dev-bronze-companies --query 'Crawler.LastCrawl'"
