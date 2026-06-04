# ── Data Lake bucket (Bronze / Silver / Gold) ─────────────────────

resource "aws_s3_bucket" "data_lake" {
  bucket = "${local.name_prefix}-data-lake-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket                  = aws_s3_bucket.data_lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    id     = "bronze-retention"
    status = "Enabled"
    filter { prefix = "bronze/" }
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 365
      storage_class = "GLACIER"
    }
  }

  rule {
    id     = "silver-retention"
    status = "Enabled"
    filter { prefix = "silver/" }
    transition {
      days          = 180
      storage_class = "STANDARD_IA"
    }
  }
}

# ── Seed folder placeholders (keeps the medallion structure visible in S3) ──

resource "aws_s3_object" "bronze_placeholder" {
  for_each = toset([
    "bronze/portfolio-companies/.keep",
    "bronze/cashflows/.keep",
    "bronze/pipeline/.keep",
    "bronze/fund-metrics/.keep",
    "silver/portfolio-companies/.keep",
    "silver/cashflows/.keep",
    "silver/pipeline/.keep",
    "gold/fund-overview/.keep",
    "gold/company-performance/.keep",
    "gold/risk-concentration/.keep",
  ])

  bucket  = aws_s3_bucket.data_lake.id
  key     = each.value
  content = ""
}

# ── Athena query results bucket ───────────────────────────────────

resource "aws_s3_bucket" "athena_results" {
  bucket = "${local.name_prefix}-athena-results-${local.account_id}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expire-query-results"
    status = "Enabled"
    filter {}
    expiration { days = 7 }
  }
}

# ── Terraform remote state bucket (bootstrap — enable backend after first apply) ──

resource "aws_s3_bucket" "tfstate" {
  bucket = "${local.name_prefix}-tfstate-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "${local.name_prefix}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
