terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ── Remote state (enable after Phase 0 bootstraps the S3 bucket) ──
  # backend "s3" {
  #   bucket         = "scp3-dev-tfstate-<ACCOUNT_ID>"
  #   key            = "pe-platform/dev/terraform.tfstate"
  #   region         = "us-west-2"
  #   dynamodb_table = "scp3-dev-tfstate-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}

# Resolve current AWS account ID and region at plan time
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  region        = data.aws_region.current.name
  name_prefix   = "${var.prefix}-${var.env}"
}
