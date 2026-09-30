provider "aws" {
  region = var.region

  # fail fast if my credentials point at the wrong account
  allowed_account_ids = [var.expected_account_id]

  default_tags {
    tags = {
      Project     = "eks-secrets-demo"
      Environment = "poc"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  name       = var.name_prefix
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  az_primary   = var.availability_zones[0]
  az_secondary = var.availability_zones[1]

  app_namespace    = "demo-app"
  secret_reader_sa = "secret-reader"

  secret_name = "demo/app/api-key"
}
