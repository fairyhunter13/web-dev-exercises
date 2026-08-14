# What the teardown role may do. A destroy has to read every resource before it
# can delete it, so each service gets its Describe/Get/List alongside its
# Delete. Scoped to this stack's ARNs wherever the service supports
# resource-level permissions; the ones that take `*` are the services that offer
# no other option, and each says so inline.

data "aws_iam_policy_document" "teardown" {
  # The state bucket, and the site bucket the destroy empties. `force_destroy`
  # on the site bucket means Terraform deletes the objects itself.
  statement {
    sid    = "Buckets"
    effect = "Allow"
    actions = [
      "s3:Get*",
      "s3:List*",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket}",
      "arn:aws:s3:::${var.state_bucket}/*",
      aws_s3_bucket.site.arn,
      "${aws_s3_bucket.site.arn}/*",
    ]
  }

  # CloudFront is global and neither its distribution nor its origin access
  # control API accepts a resource ARN, so `*` is the only expressible scope.
  # This is the widest grant here, bounded by the account holding exactly one
  # distribution.
  statement {
    sid    = "CloudFront"
    effect = "Allow"
    actions = [
      "cloudfront:Get*",
      "cloudfront:List*",
      "cloudfront:UpdateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "ApiGateway"
    effect  = "Allow"
    actions = ["apigateway:GET", "apigateway:DELETE", "apigateway:PATCH"]
    resources = [
      "arn:aws:apigateway:${var.region}::/apis",
      "arn:aws:apigateway:${var.region}::/apis/*",
      # The account-wide CloudWatch role setting. Destroy leaves it in place, as
      # apigateway.tf documents, but Terraform still reads it.
      "arn:aws:apigateway:${var.region}::/account",
    ]
  }

  statement {
    sid    = "Lambda"
    effect = "Allow"
    actions = [
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:GetPolicy",
      "lambda:ListVersionsByFunction",
      "lambda:ListTags",
      "lambda:DeleteFunction",
      "lambda:RemovePermission",
    ]
    resources = [aws_lambda_function.chat.arn]
  }

  statement {
    sid    = "DynamoDB"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:ListTagsOfResource",
      "dynamodb:DeleteTable",
    ]
    resources = [
      aws_dynamodb_table.connections.arn,
      aws_dynamodb_table.messages.arn,
    ]
  }

  statement {
    sid    = "LogGroups"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:ListTagsForResource",
      "logs:DeleteLogGroup",
    ]
    resources = [
      "${aws_cloudwatch_log_group.lambda.arn}:*",
      "${aws_cloudwatch_log_group.access.arn}:*",
    ]
  }

  statement {
    sid    = "Budget"
    effect = "Allow"
    actions = [
      "budgets:ViewBudget",
      "budgets:ModifyBudget",
      "budgets:DescribeBudget",
      "budgets:DeleteBudget",
    ]
    resources = ["arn:aws:budgets::${data.aws_caller_identity.current.account_id}:budget/*"]
  }

  # IAM, scoped by name to this stack's roles and to the hand-made deployer user
  # that teardown deletes last. `iam:*` on `*` would let this role escalate to
  # anything in the account, which is the one thing a public repository's
  # workflow must not be able to do.
  statement {
    sid    = "StackIdentities"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.name_prefix}-*"]
  }

  statement {
    sid    = "DeployerUser"
    effect = "Allow"
    actions = [
      "iam:GetUser",
      "iam:ListAccessKeys",
      "iam:ListUserPolicies",
      "iam:ListAttachedUserPolicies",
      "iam:DeleteAccessKey",
      "iam:DeleteUserPolicy",
      "iam:DetachUserPolicy",
      "iam:DeleteUser",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.deployer_user}"]
  }

  # The OIDC provider, the sweep, and the two account-level reads the archive
  # records. None of these accept a resource ARN. `ce:GetCostAndUsage` is called
  # exactly once in the lifetime of this stack, at teardown, and costs $0.01.
  statement {
    sid    = "AccountWideReadsAndOidc"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
      "iam:ListRoles",
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:DeleteOpenIDConnectProvider",
      "tag:GetResources",
      "freetier:GetAccountPlanState",
      "ce:GetCostAndUsage",
    ]
    resources = ["*"]
  }
}
