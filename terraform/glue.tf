# ── Glue Catalog Databases (one per medallion layer) ─────────────

resource "aws_glue_catalog_database" "bronze" {
  name        = "${local.name_prefix}_bronze"
  description = "Raw ingested data — unchanged from source systems"
}

resource "aws_glue_catalog_database" "silver" {
  name        = "${local.name_prefix}_silver"
  description = "Cleaned, validated and standardized data"
}

resource "aws_glue_catalog_database" "gold" {
  name        = "${local.name_prefix}_gold"
  description = "Business-ready metrics: IRR, TVPI, MOIC, HHI, computed aggregates"
}

# ── Bronze Crawlers (one per source entity) ───────────────────────
# Crawlers auto-discover schema from CSV files dropped in Bronze S3 paths.
# They run after each Bronze data load and update the Glue catalog.

resource "aws_glue_crawler" "bronze_companies" {
  name          = "${local.name_prefix}-bronze-companies"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.bronze.name
  description   = "Crawls portfolio company financials from Bronze layer"

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/bronze/portfolio-companies/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })
}

resource "aws_glue_crawler" "bronze_cashflows" {
  name          = "${local.name_prefix}-bronze-cashflows"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.bronze.name
  description   = "Crawls quarterly cash flow data from Bronze layer"

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/bronze/cashflows/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }
}

resource "aws_glue_crawler" "bronze_pipeline" {
  name          = "${local.name_prefix}-bronze-pipeline"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.bronze.name
  description   = "Crawls deal pipeline data from Bronze layer"

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/bronze/pipeline/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }
}

resource "aws_glue_crawler" "bronze_fund" {
  name          = "${local.name_prefix}-bronze-fund"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.bronze.name
  description   = "Crawls fund-level metrics from Bronze layer"

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/bronze/fund-metrics/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }
}

# ── ETL Script — uploaded from local etl/ directory ──────────────
resource "aws_s3_object" "silver_etl_script" {
  bucket = aws_s3_bucket.data_lake.bucket
  key    = "glue-scripts/silver_etl.py"
  source = "${path.module}/../etl/silver_etl.py"
  etag   = filemd5("${path.module}/../etl/silver_etl.py")
}

# ── Silver ETL Job ────────────────────────────────────────────────
resource "aws_glue_job" "silver_etl" {
  name         = "${local.name_prefix}-silver-etl"
  role_arn     = aws_iam_role.glue.arn
  glue_version = "4.0"
  worker_type  = "G.1X"
  number_of_workers = 2

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_lake.bucket}/glue-scripts/silver_etl.py"
    python_version  = "3"
  }

  default_arguments = {
    "--target_bucket"                    = aws_s3_bucket.data_lake.bucket
    "--bronze_prefix"                    = "bronze"
    "--target_prefix"                    = "silver"
    "--load_date"                        = "OVERRIDE_AT_RUNTIME"
    "--enable-glue-datacatalog"          = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = ""
    "--job-language"                     = "python"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  depends_on = [aws_s3_object.silver_etl_script]
}

# ── Silver Crawlers (one per entity, runs after Silver ETL) ───────
locals {
  silver_entities = toset([
    "portfolio_companies",
    "company_financials",
    "quarterly_cashflows",
    "fund_history",
    "fund_metrics",
    "deal_pipeline",
    "sector_breakdown",
    "geo_breakdown",
  ])
}

resource "aws_glue_crawler" "silver" {
  for_each      = local.silver_entities
  name          = "${local.name_prefix}-silver-${replace(each.key, "_", "-")}"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.silver.name
  description   = "Crawls ${each.key} Parquet from Silver layer"

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/silver/${each.key}/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })
}

# ── Gold ETL Job ──────────────────────────────────────────────────
resource "aws_s3_object" "gold_etl_script" {
  bucket = aws_s3_bucket.data_lake.bucket
  key    = "glue-scripts/gold_etl.py"
  source = "${path.module}/../etl/gold_etl.py"
  etag   = filemd5("${path.module}/../etl/gold_etl.py")
}

resource "aws_glue_job" "gold_etl" {
  name         = "${local.name_prefix}-gold-etl"
  role_arn     = aws_iam_role.glue.arn
  glue_version = "4.0"
  worker_type  = "G.1X"
  number_of_workers = 2

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_lake.bucket}/glue-scripts/gold_etl.py"
    python_version  = "3"
  }

  default_arguments = {
    "--target_bucket"                    = aws_s3_bucket.data_lake.bucket
    "--silver_prefix"                    = "silver"
    "--target_prefix"                    = "gold"
    "--enable-glue-datacatalog"          = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = ""
    "--job-language"                     = "python"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  depends_on = [aws_s3_object.gold_etl_script]
}

# ── Gold Crawlers ─────────────────────────────────────────────────
locals {
  gold_entities = toset([
    "fund_kpis",
    "nav_history",
    "cashflow_jcurve",
    "sector_allocation",
    "geo_allocation",
    "portfolio_table",
    "company_financials",
    "pipeline",
    "risk_summary",
    "risk_leverage_bands",
    "risk_moic_bands",
  ])
}

resource "aws_glue_crawler" "gold" {
  for_each      = local.gold_entities
  name          = "${local.name_prefix}-gold-${replace(each.key, "_", "-")}"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.gold.name
  description   = "Crawls ${each.key} Parquet from Gold layer"

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/gold/${each.key}/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }
}
