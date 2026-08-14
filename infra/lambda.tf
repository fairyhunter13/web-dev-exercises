# The binary is built outside Terraform, by deploy.sh. A null_resource with a
# local-exec is invisible to `terraform plan`, so the plan would look clean
# while shipping a stale binary. Building first and hashing the artifact puts
# the drift in the plan.
data "archive_file" "chat" {
  type = "zip"
  # Lambda's custom runtime requires the executable to be named `bootstrap` and
  # to sit at the root of the zip, not in a subdirectory.
  source_file = "${path.module}/build/bootstrap"
  output_path = "${path.module}/build/chat.zip"
}

resource "aws_lambda_function" "chat" {
  function_name = "${var.name_prefix}-ws"
  role          = aws_iam_role.lambda.arn

  # provided.al2023 is the current custom runtime; provided.al2 reached end of
  # support in July 2026. arm64 is around 20% cheaper per GB-second than x86_64
  # and Go cross-compiles to it with no change to the source.
  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap"

  filename         = data.archive_file.chat.output_path
  source_code_hash = data.archive_file.chat.output_base64sha256

  # 256 MB, above the 128 MB minimum. CPU is allocated in proportion to memory,
  # so a larger function often finishes faster and costs the same or less in
  # GB-seconds. The CloudWatch duration metric is where you check that.
  memory_size = 256
  timeout     = 10

  # No reserved_concurrent_executions. This account's total concurrency limit
  # is 10 (the default for a new, unreviewed
  # account), and Lambda refuses any reservation that would drop unreserved
  # concurrency below 10, returning InvalidParameterValueException from
  # PutFunctionConcurrency. The account limit is therefore already the hard
  # ceiling a per-function reservation would have provided, and the stage
  # throttle in apigateway.tf caps arrivals ahead of it. On an account with the
  # usual 1000 limit, set this to 5.

  environment {
    variables = {
      CONNECTIONS_TABLE = aws_dynamodb_table.connections.name
      MESSAGES_TABLE    = aws_dynamodb_table.messages.name
    }
  }

  # The deploy workflow calls UpdateFunctionCode, so without this the next local
  # plan would want to roll the function back to whatever binary was last built
  # on this machine. Everything else about the function, including memory,
  # timeout, runtime and environment, is still Terraform's and still shows up in
  # a plan.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

# Declared explicitly so the retention is set. Left to Lambda, the log group is
# created implicitly with retention "never expire", and the logs then accrue
# storage charges forever after the stack is destroyed.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-ws"
  retention_in_days = 7
}

resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  statement {
    sid    = "Tables"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:Scan",
    ]
    resources = [
      aws_dynamodb_table.connections.arn,
      aws_dynamodb_table.messages.arn,
    ]
  }

  statement {
    sid    = "PostToConnections"
    effect = "Allow"
    # The resource for @connections is the API's execution ARN plus
    # stage/METHOD/@connections/{id}. Granting it as "<api>/@connections/*"
    # is the common mistake and produces a 403 at runtime that looks like a
    # broken client.
    actions   = ["execute-api:ManageConnections"]
    resources = ["${aws_apigatewayv2_api.chat.execution_arn}/*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.name_prefix}-lambda"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}
