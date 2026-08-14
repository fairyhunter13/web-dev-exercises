resource "aws_apigatewayv2_api" "chat" {
  name          = "${var.name_prefix}-ws"
  protocol_type = "WEBSOCKET"

  # Which route a frame goes to is read from its own "type" field, so the wire
  # protocol the client already uses doubles as the routing key. Anything whose
  # type has no route falls through to $default.
  route_selection_expression = "$request.body.type"
}

resource "aws_apigatewayv2_integration" "chat" {
  api_id = aws_apigatewayv2_api.chat.id

  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.chat.invoke_arn

  # WebSocket APIs only support 1.0 request/response templates; setting 2.0 as
  # one does for HTTP APIs fails at deploy time.
  integration_method = "POST"
}

locals {
  # $default catches every frame whose type has no dedicated route, including
  # "send" and "ping". One handler switches on the type, so splitting them into
  # separate routes would only duplicate the wiring.
  routes = ["$connect", "$disconnect", "$default"]
}

resource "aws_apigatewayv2_route" "chat" {
  for_each = toset(local.routes)

  api_id    = aws_apigatewayv2_api.chat.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.chat.id}"
}

# WebSocket APIs are not auto-deployed.
#
# `auto_deploy` on the stage is HTTP-API-only: the provider documents it as
# "Applicable for HTTP APIs". On a WebSocket API it is silently ignored, so
# without an explicit deployment the API serves whatever configuration existed
# at creation and quietly disregards every later route change. The triggers hash
# forces a new deployment whenever the routing actually changes, and
# create_before_destroy keeps the stage pointing at a live deployment
# throughout.
resource "aws_apigatewayv2_deployment" "chat" {
  api_id = aws_apigatewayv2_api.chat.id

  triggers = {
    redeploy = sha1(jsonencode([
      aws_apigatewayv2_integration.chat,
      [for r in aws_apigatewayv2_route.chat : r.route_key],
      aws_lambda_function.chat.source_code_hash,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_apigatewayv2_route.chat]
}

# Access logging is an account-level setting before it is a stage-level one.
#
# API Gateway writes access logs under a role it assumes itself, and that role
# is configured once per account and region rather than per API. On an account
# that has never had it set -- a brand-new one, for instance -- creating a stage
# with access_log_settings fails with "CloudWatch Logs role ARN must be set in
# account settings". The v1 `aws_api_gateway_account` resource is the only way
# to set it, and despite the name it governs v2 APIs as well.
#
# It is account-wide, so `terraform destroy` leaves it behind. Removing it
# would break logging for any other API in the account.
resource "aws_iam_role" "apigw_logs" {
  name = "${var.name_prefix}-apigw-cloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "apigw_logs" {
  role       = aws_iam_role.apigw_logs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.apigw_logs.arn

  depends_on = [aws_iam_role_policy_attachment.apigw_logs]
}

resource "aws_apigatewayv2_stage" "chat" {
  api_id        = aws_apigatewayv2_api.chat.id
  name          = "live"
  deployment_id = aws_apigatewayv2_deployment.chat.id

  depends_on = [aws_api_gateway_account.this]

  # Throttling is the cost control that matters here. API Gateway WebSocket is
  # not an always-free service and is billed per message, so without a cap a
  # loop in a client, or someone pointing a script at a public demo URL, turns
  # into a bill. The numbers come from the actual demand: a reviewer opening two
  # windows and typing needs single digits per second, so 5/s sustained with a
  # burst of 10 absorbs a reconnect storm and still bounds a month of sustained
  # hammering to something small.
  default_route_settings {
    throttling_rate_limit  = 5
    throttling_burst_limit = 10
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId    = "$context.requestId"
      routeKey     = "$context.routeKey"
      connectionId = "$context.connectionId"
      status       = "$context.status"
      error        = "$context.error.message"
      latency      = "$context.responseLatency"
    })
  }
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${var.name_prefix}-ws"
  retention_in_days = 7
}

# Without this, API Gateway gets a 403 trying to invoke the function and the
# client sees a handshake that simply fails.
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.chat.execution_arn}/*/*"
}
