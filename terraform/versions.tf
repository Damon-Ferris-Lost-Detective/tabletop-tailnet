terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
    # Credentials come from the environment, never from this repo:
    #   TAILSCALE_API_KEY   (a tskey-api-... key; expires after <= 90 days)
    #   TAILSCALE_TAILNET   (your tailnet name, or "-" for the key's default tailnet)
    tailscale = {
      source  = "tailscale/tailscale"
      version = ">= 0.17"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.name
      ManagedBy = "terraform"
    }
  }
}

provider "tailscale" {}
