# ── Lambda Function ───────────────────────────────────────────────

resource "aws_lambda_function" "api" {
  function_name    = "${local.name_prefix}-api"
  role             = aws_iam_role.lambda_api.arn
  filename         = "${path.module}/../api/lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/../api/lambda.zip")
  handler          = "main.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      ATHENA_DB        = aws_glue_catalog_database.gold.name
      ATHENA_WORKGROUP = aws_athena_workgroup.main.name
      ATHENA_OUTPUT    = "s3://${aws_s3_bucket.athena_results.bucket}/query-results/"
    }
  }
}

# ── API Gateway HTTP API (v2) ─────────────────────────────────────

resource "aws_apigatewayv2_api" "api" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# ── Outputs ───────────────────────────────────────────────────────

output "api_url" {
  description = "API Gateway invoke URL — base URL for all dashboard endpoints"
  value       = aws_apigatewayv2_stage.default.invoke_url
}
