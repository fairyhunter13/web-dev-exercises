terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # State lives in S3 rather than on the workstation, because the scheduled
  # teardown (see teardown.yml) runs from a fresh CI checkout: against local
  # state it would find nothing to destroy and exit 0, reporting success having
  # deleted nothing.
  #
  # The bucket is created by hand, not by this config, because a backend must
  # exist before the config that would create it. It is versioned, so a
  # corrupted state has a predecessor, and teardown deletes it explicitly as its
  # last step - nothing else will.
  #
  # No `profile` here on purpose: CI authenticates by OIDC and has no profile to
  # name. Locally, set AWS_PROFILE (deploy.sh does). If it is unset the backend
  # falls back to default credentials, which cannot reach this bucket, so the
  # failure is a clean AccessDenied rather than a write into the wrong account.
  backend "s3" {
    bucket = "chat-tfstate-e7ba8e48"
    key    = "chat/terraform.tfstate"
    region = "ap-southeast-1"

    # S3-native locking. The DynamoDB lock table this used to require is no
    # longer needed, and is one more resource teardown would have to remove.
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  # Never the default profile. Workstations accumulate credentials for accounts
  # that have nothing to do with this stack, and a stray apply into one of them
  # would be a serious incident. var.aws_profile validates against "default".
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "web-dev-exercises"
      ManagedBy = "terraform"
    }
  }
}

# Budgets is a global service whose API lives in us-east-1, as does the ACM
# certificate a custom CloudFront domain would need.
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "web-dev-exercises"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
