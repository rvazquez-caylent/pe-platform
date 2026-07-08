# ── Lake Formation ────────────────────────────────────────────────
# This account has LF enabled in strict mode (empty default permissions).
# We use LF only for Glue catalog-level access control. S3 data access
# remains IAM-controlled (DO NOT register the S3 bucket with LF — that
# routes data access through the LF SLR and breaks Athena reads unless
# the SLR has explicit bucket access).

# Set SSO admin as LF admin; enable IAM pass-through for future objects
resource "aws_lakeformation_data_lake_settings" "main" {
  admins = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_370d0a9b30d49146"
  ]

  create_database_default_permissions {
    principal   = "IAM_ALLOWED_PRINCIPALS"
    permissions = ["ALL"]
  }

  create_table_default_permissions {
    principal   = "IAM_ALLOWED_PRINCIPALS"
    permissions = ["ALL"]
  }
}

# ── Glue crawler role — catalog write permissions ─────────────────

resource "aws_lakeformation_permissions" "glue_bronze_db" {
  principal   = aws_iam_role.glue.arn
  permissions = ["CREATE_TABLE", "DESCRIBE", "ALTER", "DROP"]

  database {
    name = aws_glue_catalog_database.bronze.name
  }

  depends_on = [aws_lakeformation_data_lake_settings.main]
}

resource "aws_lakeformation_permissions" "glue_bronze_tables" {
  principal   = aws_iam_role.glue.arn
  permissions = ["ALL"]

  table {
    database_name = aws_glue_catalog_database.bronze.name
    wildcard      = true
  }

  depends_on = [aws_lakeformation_permissions.glue_bronze_db]
}

# ── IAM_ALLOWED_PRINCIPALS — Athena / console read access ─────────
# Grants all IAM-authorized roles catalog DESCRIBE access on the three
# medallion databases so Athena can resolve table metadata.

resource "aws_lakeformation_permissions" "iam_bronze_db" {
  principal   = "IAM_ALLOWED_PRINCIPALS"
  permissions = ["ALL"]

  database {
    name = aws_glue_catalog_database.bronze.name
  }

  depends_on = [aws_lakeformation_data_lake_settings.main]
}

resource "aws_lakeformation_permissions" "iam_silver_db" {
  principal   = "IAM_ALLOWED_PRINCIPALS"
  permissions = ["ALL"]

  database {
    name = aws_glue_catalog_database.silver.name
  }

  depends_on = [aws_lakeformation_data_lake_settings.main]
}

resource "aws_lakeformation_permissions" "iam_gold_db" {
  principal   = "IAM_ALLOWED_PRINCIPALS"
  permissions = ["ALL"]

  database {
    name = aws_glue_catalog_database.gold.name
  }

  depends_on = [aws_lakeformation_data_lake_settings.main]
}
