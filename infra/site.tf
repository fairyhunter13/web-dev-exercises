resource "aws_s3_bucket" "site" {
  bucket        = "${var.name_prefix}-site-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # a build output; nothing here is worth protecting from destroy
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Origin Access Control, not the legacy Origin Access Identity. OAI is
# deprecated, does not support SigV4-only regions, and cannot sign requests to
# an S3 bucket using KMS. The bucket stays fully private; CloudFront is the only
# reader.
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.name_prefix}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "site" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    # Scoped to this one distribution, so the policy does not quietly allow any
    # CloudFront distribution in any account to read the bucket.
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "${var.name_prefix} SPA"

  # PriceClass_200 includes Singapore and Jakarta, which covers the readers of
  # this repo. PriceClass_All would pay for edge locations nobody uses.
  price_class = "PriceClass_200"

  origin {
    # The REST endpoint (bucket.s3.region.amazonaws.com) rather than the S3
    # website endpoint. OAC cannot sign requests to the website endpoint, and
    # that endpoint requires the bucket to be public, which is what OAC exists
    # to avoid.
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed policies, by id: CachingOptimized. Writing a custom policy
    # here would be more configuration for identical behaviour.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # The REST origin has no directory-index behaviour, so a deep link returns
  # 403 from S3 rather than 404. Both are mapped back to index.html so the SPA
  # router can handle the path.
  dynamic "custom_error_response" {
    for_each = [403, 404]
    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 10
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # The default *.cloudfront.net certificate. A custom domain would need an
    # ACM certificate in us-east-1 and a domain to point at it; neither adds
    # anything to a demo link.
    cloudfront_default_certificate = true
  }
}
