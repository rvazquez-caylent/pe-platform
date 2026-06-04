# PE Platform — Infrastructure

AWS data lake for the Private Equity Intelligence Platform.
**Stack:** S3 (Medallion) · Glue · Athena · Lambda · API Gateway · Cognito

---

## Prerequisites

| Tool | Version | Check |
|---|---|---|
| Terraform | >= 1.7 | `terraform --version` |
| AWS CLI | >= 2.x | `aws --version` |
| Node.js | >= 18 | `node --version` |
| Python | >= 3.10 | `python3 --version` |

---

## Phase 0 — Bootstrap (you are here)

### Step 1 — Configure AWS credentials
```bash
aws configure
# AWS Access Key ID: <your key>
# AWS Secret Access Key: <your secret>
# Default region: us-west-2
# Default output format: json
```
Verify: `aws sts get-caller-identity`

### Step 2 — Initialize Terraform
```bash
cd terraform
terraform init
```

### Step 3 — Review the plan
```bash
terraform plan
```
You should see ~20 resources to create (3 S3 buckets, IAM roles, Glue databases + crawlers, Athena workgroup, DynamoDB table).

### Step 4 — Apply
```bash
terraform apply
# Type 'yes' when prompted
```
Note the outputs — especially `data_lake_bucket`. You'll need it in Step 6.

### Step 5 — Generate seed CSVs
```bash
cd ../seeds
node generate_seeds.js
# Creates ./csv/ with 9 CSV files from the demo data
```

### Step 6 — Upload seeds to Bronze
```bash
bash upload_seeds.sh <DATA_LAKE_BUCKET_NAME>
# e.g.: bash upload_seeds.sh scp3-dev-data-lake-123456789012
```

### Step 7 — Run Glue crawlers
```bash
aws glue start-crawler --name scp3-dev-bronze-companies --region us-west-2
aws glue start-crawler --name scp3-dev-bronze-cashflows  --region us-west-2
aws glue start-crawler --name scp3-dev-bronze-pipeline   --region us-west-2
aws glue start-crawler --name scp3-dev-bronze-fund       --region us-west-2
```
Crawlers take ~2 minutes. Check status:
```bash
aws glue get-crawler --name scp3-dev-bronze-companies \
  --query 'Crawler.LastCrawl.Status' --output text
```
Expected: `SUCCEEDED`

### Step 8 — Verify in Athena
Open the AWS Console → Athena → select workgroup `scp3-dev-workgroup` → run:
```sql
SHOW TABLES IN scp3_dev_bronze;
```
You should see: `portfolio_companies`, `cashflows`, `pipeline`, `fund_metrics`

---

## Phase 1 — Coming next
- Glue ETL: Bronze → Silver (cleaning, validation)
- dbt: Silver → Gold (IRR, TVPI, MOIC computed)

## Phase 2 — After that
- FastAPI Lambda
- API Gateway
- Connect dashboards to live data

---

## Project Structure

```
pe-platform/
├── terraform/
│   ├── main.tf         Provider, locals, account ID resolution
│   ├── variables.tf    Input variables (prefix, env, region)
│   ├── outputs.tf      Bucket names, ARNs, database names
│   ├── s3.tf           Data lake + Athena results + Terraform state buckets
│   ├── iam.tf          Glue role + Lambda API role
│   ├── glue.tf         Catalog databases + Bronze crawlers
│   └── athena.tf       Athena workgroup (engine v3, encrypted results)
├── seeds/
│   ├── generate_seeds.js   Exports demo data.js → CSVs
│   ├── upload_seeds.sh     Uploads CSVs to S3 Bronze paths
│   └── csv/                (generated — gitignored)
├── etl/                    Phase 1: Glue ETL scripts
├── api/                    Phase 2: FastAPI application
└── README.md               This file
```

---

## Naming Convention

All resources follow: `{prefix}-{env}-{resource}-{account_id}`

| Variable | Default | Meaning |
|---|---|---|
| `prefix` | `scp3` | Fund short name |
| `env` | `dev` | Environment (`dev` / `staging` / `prod`) |

Change in `terraform/variables.tf` before applying.
