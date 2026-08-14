output "wss_url" {
  description = "WebSocket endpoint. Goes into the frontend build as VITE_WS_URL."
  value       = aws_apigatewayv2_stage.chat.invoke_url
}

output "site_url" {
  description = "Public URL of the chat app."
  value       = "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "site_bucket" {
  description = "Bucket the built frontend is synced to."
  value       = aws_s3_bucket.site.id
}

output "ci_role_arn" {
  description = "Role GitHub Actions assumes. Goes into the AWS_ROLE_ARN repository secret."
  value       = aws_iam_role.ci.arn
}

output "teardown_role_arn" {
  description = "Role the scheduled teardown assumes. Goes into the AWS_TEARDOWN_ROLE_ARN repository secret."
  value       = aws_iam_role.teardown.arn
}

output "lambda_function_name" {
  description = "Target of UpdateFunctionCode in the deploy workflow."
  value       = aws_lambda_function.chat.function_name
}

output "distribution_id" {
  description = "Needed to invalidate the edge cache after a deploy."
  value       = aws_cloudfront_distribution.site.id
}
