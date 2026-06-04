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
