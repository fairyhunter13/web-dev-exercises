# The role the scheduled teardown assumes. Separate from the deploy role on
# purpose: `ci-deploy` grants six actions on four ARNs and is deliberately
# unable to delete anything, so a destroy under it would fail with AccessDenied
# on its very first action.
#
# Same trust shape as the deploy role, pinned to a different environment. The
# two gotchas documented in github_oidc.tf apply here identically: the
# environment form replaces the ref in the sub claim, and the repository part is
# the immutable ID-based prefix.
#
# The `teardown` environment must not carry required reviewers. A scheduled run
# is nobody's foreground task, so an approval gate does not protect it - it just
# hangs until the account closes on its own.
#
# The policy itself is in teardown_policy.tf.

data "aws_iam_policy_document" "teardown_assume" {
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

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.github_sub_claim_prefix}:environment:${var.teardown_environment}"]
    }
  }
}

resource "aws_iam_role" "teardown" {
  name               = "${var.name_prefix}-teardown"
  description        = "Assumed by the scheduled teardown workflow to archive and destroy this stack."
  assume_role_policy = data.aws_iam_policy_document.teardown_assume.json
}

resource "aws_iam_role_policy" "teardown" {
  name   = "${var.name_prefix}-teardown"
  role   = aws_iam_role.teardown.id
  policy = data.aws_iam_policy_document.teardown.json
}
