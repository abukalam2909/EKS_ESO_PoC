terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.66.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "= 2.8.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "= 4.4.1"
    }
  }

  # local state for the poc. no secret values end up in state since terraform
  # never writes a secret version.
}
