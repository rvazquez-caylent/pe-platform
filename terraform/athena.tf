# ── Athena Workgroup ──────────────────────────────────────────────

resource "aws_athena_workgroup" "main" {
  name        = "${local.name_prefix}-workgroup"
  description = "PE Platform — all Athena queries for ETL and API layer"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/query-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }
}
