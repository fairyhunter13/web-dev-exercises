# The role GitHub Actions assumes to deploy. No access key is ever created or
# stored: the workflow presents a short-lived OIDC token and AWS exchanges it for
# credentials that expire with the job.
#
# Terraform still owns the infrastructure and is applied from a workstation,
# because the state is local (see versions.tf). This role therefore grants only
# what is needed to ship *code* into infrastructure that already exists.

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # The thumbprint is no longer validated for this provider, since IAM pins
  # GitHub's trust chain itself, but the API still requires the field.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "ci_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Pinned to one deployment environment of one repository. Writing
    # "repo:owner/*" here, as many examples do, lets a workflow in any fork or
    # any branch of a public repo assume this role.
    #
    # Two things here are easy to get wrong, and neither gives a diagnosable
    # error: both fail as a bare "Not authorized to perform
    # sts:AssumeRoleWithWebIdentity". Read the value off an actual token.
    #
    # 1. It uses the environment form, not "ref:refs/heads/main".
    #    Declaring `environment:` in a job *replaces* the ref in the sub claim
    #    instead of adding to it, so a branch-pinned policy rejects the very job
    #    it was written for. Pinning the environment is the stronger of the two
    #    anyway: an environment can carry approval rules, a branch cannot.
    # 2. The repository part is an immutable ID-based prefix, not "owner/repo".
    #    See the variable for how to read it.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_sub_claim_prefix}:environment:${var.github_environment}"]
    }
  }
}

resource "aws_iam_role" "ci" {
  name               = "${var.name_prefix}-ci-deploy"
  description        = "Assumed by GitHub Actions to publish the frontend and the Lambda binary."
  assume_role_policy = data.aws_iam_policy_document.ci_assume.json
}

data "aws_iam_policy_document" "ci" {
  # Two separate ARNs: object actions apply to the contents, ListBucket applies
  # to the bucket itself, and `aws s3 sync --delete` needs both.
  statement {
    sid    = "PublishSite"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.site.arn}/*"]
  }

  statement {
    sid       = "ListSite"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.site.arn]
  }

  statement {
    sid       = "InvalidateEdgeCache"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [aws_cloudfront_distribution.site.arn]
  }

  # UpdateFunctionCode but not UpdateFunctionConfiguration, which would let a
  # workflow change memory, timeout or environment behind Terraform's back.
  # GetFunctionConfiguration is read-only and is what `aws lambda wait
  # function-updated` polls to confirm the update finished.
  statement {
    sid    = "ShipLambdaCode"
    effect = "Allow"
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:GetFunctionConfiguration",
    ]
    resources = [aws_lambda_function.chat.arn]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "${var.name_prefix}-ci-deploy"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}
