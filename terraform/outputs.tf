output "data_lake_bucket" {
  description = "S3 data lake bucket name (use this in all ETL scripts)"
  value       = aws_s3_bucket.data_lake.bucket
}

output "athena_results_bucket" {
  description = "S3 bucket for Athena query results"
  value       = aws_s3_bucket.athena_results.bucket
}

output "athena_workgroup" {
  description = "Athena workgroup name"
  value       = aws_athena_workgroup.main.name
}

output "glue_role_arn" {
  description = "IAM role ARN for Glue jobs and crawlers"
  value       = aws_iam_role.glue.arn
}

output "lambda_role_arn" {
  description = "IAM role ARN for Lambda API functions"
  value       = aws_iam_role.lambda_api.arn
}

output "glue_database_bronze" {
  description = "Glue catalog database — Bronze layer"
  value       = aws_glue_catalog_database.bronze.name
}

output "glue_database_silver" {
  description = "Glue catalog database — Silver layer"
  value       = aws_glue_catalog_database.silver.name
}

output "glue_database_gold" {
  description = "Glue catalog database — Gold layer"
  value       = aws_glue_catalog_database.gold.name
}

output "tfstate_bucket" {
  description = "S3 bucket for Terraform remote state (use in backend config after first apply)"
  value       = aws_s3_bucket.tfstate.bucket
}

output "tfstate_dynamodb_table" {
  description = "DynamoDB table for Terraform state locking"
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "bronze_companies_s3_path" {
  description = "S3 path for Bronze portfolio company data — drop CSVs here"
  value       = "s3://${aws_s3_bucket.data_lake.bucket}/bronze/portfolio-companies/"
}

output "bronze_cashflows_s3_path" {
  description = "S3 path for Bronze cash flow data"
  value       = "s3://${aws_s3_bucket.data_lake.bucket}/bronze/cashflows/"
}

output "bronze_pipeline_s3_path" {
  description = "S3 path for Bronze deal pipeline data"
  value       = "s3://${aws_s3_bucket.data_lake.bucket}/bronze/pipeline/"
}

output "bronze_fund_s3_path" {
  description = "S3 path for Bronze fund metrics data"
  value       = "s3://${aws_s3_bucket.data_lake.bucket}/bronze/fund-metrics/"
}
