variable "region" {
  description = "Region for everything except the budget. Singapore is the closest to Jakarta."
  type        = string
  default     = "ap-southeast-1"
}

variable "aws_profile" {
  description = "Named profile in ~/.aws/config. Must not be the default profile."
  type        = string
  default     = "chat-demo"

  validation {
    condition     = var.aws_profile != "default" && var.aws_profile != ""
    error_message = "Set an explicit named profile; applying under the default profile is not allowed."
  }
}

variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "chat"
}

variable "github_sub_claim_prefix" {
  description = <<-EOT
    Prefix of the `sub` claim in the OIDC token this repository's workflows present.
    Read it, do not assume it:

      gh api repos/OWNER/REPO/actions/oidc/customization/sub -q .sub_claim_prefix

    GitHub issues an immutable, ID-based prefix, "repo:owner@<user-id>/repo@<repo-id>",
    rather than the readable "repo:owner/repo" that most examples show. A trust policy
    written from the readable form is rejected with "Not authorized to perform
    sts:AssumeRoleWithWebIdentity" and no indication of which condition failed. The
    ID-based form also survives a rename of either the account or the repository, where
    the readable form would silently start matching whoever claims the old name. It does
    not survive the repository being deleted and created again under the same name: that
    issues a new repository ID, and the trust policy has to be applied again with it.
  EOT
  type        = string
  default     = "repo:fairyhunter13@12372147/web-dev-exercises@1333724481"

  validation {
    condition     = startswith(var.github_sub_claim_prefix, "repo:")
    error_message = "Expected the prefix reported by the OIDC customization API, which starts with repo:."
  }
}

variable "github_environment" {
  description = "Deployment environment the workflow declares. Must match deploy.yml."
  type        = string
  default     = "production"
}

variable "teardown_environment" {
  description = "Deployment environment the teardown workflow declares. Must match teardown.yml, and must have no required reviewers."
  type        = string
  default     = "teardown"
}

variable "state_bucket" {
  description = <<-EOT
    Bucket holding the Terraform state. Created by hand and deliberately not
    managed here: a backend must exist before the config that would create it.
    Repeated from the backend block in versions.tf, which cannot take variables.
    Teardown empties and deletes it explicitly, after the destroy.
  EOT
  type        = string
  default     = "chat-tfstate-e7ba8e48"
}

variable "deployer_user" {
  description = <<-EOT
    Hand-made IAM user with a long-lived access key, predating the OIDC roles
    and in no .tf file. It is the break-glass identity if OIDC ever fails, so
    teardown deletes it last, and it is invisible to a tag sweep because the
    Resource Groups Tagging API does not cover IAM.
  EOT
  type        = string
  default     = "chat-demo-deployer"
}

variable "budget_email" {
  description = "Address that receives the cost alert."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly spend that triggers the alert. The whole stack should cost cents."
  type        = string
  default     = "5"
}
