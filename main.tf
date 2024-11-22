# AWS Account Information
data "aws_caller_identity" "current" {}

# Random Suffix for Bucket Names
resource "random_string" "bucket_suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  bucket_gen = random_string.bucket_suffix.result
}

# ------------------------- WebSite S3 Static Bucket ------------------------- #

# Website S3 Bucket
resource "aws_s3_bucket" "website_bucket" {
  bucket = "cloud-resume-${local.bucket_gen}"

  tags = {
    Name = "cloud-resume-${local.bucket_gen}"
  }
}

/*
Prevents any public access, even if misconfigured ACLs are applied.

Purpose: Enforces restrictions on public access at the bucket level. 
Even if an object-level ACL is misconfigured or attempts are made to add public ACLs, this configuration ensures public access is blocked.

Use Case: Provides an additional layer of protection if your setup involves multiple users or tools that might inadvertently apply public ACLs.
*/
resource "aws_s3_bucket_public_access_block" "public_access_block" {
  bucket                  = aws_s3_bucket.website_bucket.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

/*
  Ensures the bucket owner (you) retains ownership of all uploaded objects, 
  even if a different AWS account uploads files with specific ACLs.

  Prevents objects from being inaccessible due to ownership conflicts 
  but does not inherently prevent public access.
*/
resource "aws_s3_bucket_ownership_controls" "ownership_controls" {
  bucket = aws_s3_bucket.website_bucket.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

/*
Purpose: Defines the default access control list for the bucket 
(e.g., private, public-read, etc.).
Ensures objects inherit the specified ACL (in this case, private) by default 
when uploaded. However, this does not prevent users from explicitly setting public ACLs.
*/
resource "aws_s3_bucket_acl" "bucket_acl" {
  bucket = aws_s3_bucket.website_bucket.id
  acl    = "private"

  depends_on = [aws_s3_bucket_ownership_controls.ownership_controls]
}

resource "aws_s3_bucket_website_configuration" "website_configuration" {
  bucket = aws_s3_bucket.website_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

# SUPER IMPORTANT, ALOOWS TRAFFIC TO COME FROM CLOUDFRONT, CHANING DOMAINS
resource "aws_s3_bucket_cors_configuration" "cors_configuration" {
  bucket = aws_s3_bucket.website_bucket.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
    expose_headers  = []
  }
}

# SUPER IMPORTANT: A bucket policy to the website_bucket to allow access via the CloudFront OAC

resource "aws_s3_bucket_policy" "website_bucket_policy" {
  bucket = aws_s3_bucket.website_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid      = "AllowGetCloudFrontAccess",
        Effect   = "Allow",
        Principal = {
          Service = "cloudfront.amazonaws.com"
        },
        Action   = "s3:GetObject",
        Resource = "arn:aws:s3:::${aws_s3_bucket.website_bucket.id}/*",
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      },
      {
        Sid      = "AllowIAMAdminToPutObject",
        Effect   = "Allow",
        Principal = {
          AWS = "arn:aws:iam::761018880324:user/iamadmin"
        },
        Action   = "s3:PutObject",
        Resource = "arn:aws:s3:::${aws_s3_bucket.website_bucket.id}/*",
            // Condition = {
            //"AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
            /*
            Your policy is almost correct, but there’s a small issue: AWS:SourceArn is not a valid condition key for s3:PutObject actions. 
            AWS:SourceArn is commonly used for services like Lambda or CloudFront to restrict access, but it does not apply when granting permissions for an IAM user (iamadmin) to upload objects.
            */
      }
    ]
  })

  depends_on = [aws_cloudfront_distribution.cdn]
}

/* If you need to restrict uploads from iamadmin to happen only through CloudFront, you cannot directly use AWS:SourceArn. Instead, you should use the following strategies:

Allow CloudFront to access the bucket via OAC or OAI.
Separate permissions for iamadmin and ensure iamadmin has direct upload rights without conflicting with CloudFront policies.*/


# ------------------------- S3 CV Bucket for AWS SES ------------------------- #

# CV S3 Bucket
resource "aws_s3_bucket" "cv_bucket" {
  bucket = "cv-${local.bucket_gen}"

  tags = {
    Name = "cv-${local.bucket_gen}"
  }
}

# Upload CV File to S3
resource "aws_s3_object" "cv_file" {
  bucket       = aws_s3_bucket.cv_bucket.id
  key          = "cv.pdf"
  source       = "CV.pdf"  # Ensure this file exists in your working directory
  content_type = "application/pdf"
}

# S3 Bucket Policy for CV Bucket
resource "aws_s3_bucket_policy" "cv_bucket_policy" {
  bucket = aws_s3_bucket.cv_bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid      = "AllowCloudFrontAccessWithSignedURLs",
        Effect   = "Allow",
        Principal = {
          Service = "cloudfront.amazonaws.com"
        },
        Action   = "s3:GetObject",
        Resource = "arn:aws:s3:::${aws_s3_bucket.cv_bucket.id}/*",
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })

  depends_on = [aws_cloudfront_distribution.cdn]
}

# ------------------------- Verify SES Email Identity ------------------------- #

resource "aws_ses_email_identity" "verified_sender" {
  email = var.verified_sender_email
}

# ------------------------- IAM Role and Policies ------------------------- #

# IAM Role for Lambda Functions
resource "aws_iam_role" "lambda_role" {
  name = "lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        },
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# Policy to Allow Lambda to Send Emails via SES
resource "aws_iam_policy" "ses_send_policy" {
  name        = "SESSendPolicy"
  description = "Allows Lambda to send emails via SES"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["ses:SendEmail", "ses:SendRawEmail"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_ses_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.ses_send_policy.arn
}

# Policy to Allow Lambda to Access Parameter Store
resource "aws_iam_policy" "ssm_parameter_access" {
  name        = "SSMParameterAccess"
  description = "Allows Lambda to read parameters from Parameter Store"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect: "Allow",
        Action: [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ],
        Resource: [
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/cloudfront/private_key",
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/cloudfront/key_pair_id"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_ssm_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.ssm_parameter_access.arn
}

# Attach Basic Execution Role for Lambda
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ------------------------- SSM Parameters ------------------------- #

# CloudFront Private Key Parameter
resource "aws_ssm_parameter" "cloudfront_private_key" {
  name        = "/cloudfront/private_key"
  description = "CloudFront private key for signed URLs"
  type        = "SecureString"
  value       = var.cloudfront_private_key
}

# CloudFront Key Pair ID Parameter
resource "aws_ssm_parameter" "cloudfront_key_pair_id" {
  name        = "/cloudfront/key_pair_id"
  description = "CloudFront key pair ID for signed URLs"
  type        = "SecureString"
  value       = var.cloudfront_key_pair_id
}

# ------------------------- Lambda Function for SES ------------------------- #

resource "aws_lambda_function" "ses_lambda" {
  filename      = "SES_lambda.zip"
  function_name = "SESFunction"
  role          = aws_iam_role.lambda_role.arn
  handler       = "SES_lambda.lambda_handler"
  runtime       = "python3.9"

  environment {
    variables = {
      SENDER_EMAIL   = aws_ses_email_identity.verified_sender.email
      CLOUDFRONT_URL = "https://${aws_cloudfront_distribution.cdn.domain_name}/cv.pdf"
    }
  }

  depends_on = [
    aws_ses_email_identity.verified_sender,
    aws_iam_role_policy_attachment.lambda_ses_policy_attachment,
    aws_iam_role_policy_attachment.lambda_ssm_policy_attachment,
    aws_iam_role_policy_attachment.lambda_basic_execution
  ]

  layers = [aws_lambda_layer_version.rsa_layer.arn]
}

# Lambda Layer Resource
resource "aws_lambda_layer_version" "rsa_layer" {
  filename          = "lambda_layer.zip"
  layer_name        = "rsa_dependency_layer"
  compatible_runtimes = ["python3.9"]  # Adjust if you're using a different Python version
  description       = "Lambda Layer containing the rsa library"
}


# ------------------------- CloudFront Distribution ------------------------- #

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "cloud-resume-oac"
  description                       = "OAC for CloudFront to access S3 bucket securely"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name              = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.website_bucket.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  origin {
    domain_name = aws_s3_bucket.cv_bucket.bucket_regional_domain_name
    origin_id   = "S3-${aws_s3_bucket.cv_bucket.id}"
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.website_bucket.id}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }

ordered_cache_behavior {
  path_pattern           = "cv.pdf"
  allowed_methods        = ["GET", "HEAD"]
  cached_methods         = ["GET", "HEAD"]
  target_origin_id       = "S3-${aws_s3_bucket.cv_bucket.id}"
  viewer_protocol_policy = "redirect-to-https"

  forwarded_values {
    query_string = true  # Required for signed URLs
    cookies {
      forward = "none"
    }
  }
  # Use CloudFront key-pair signing
  trusted_signers = ["self"] 
  # The new error suggests that CloudFront is no longer looking for AWSAccessKeyId (indicating it's now properly configured for signed URLs) 
  # Doesn't search for AWSAccessKeyId anymore.
}

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = false
    acm_certificate_arn            = aws_acm_certificate.cert_for_cloudflare_dns.arn
    ssl_support_method              = "sni-only"
    minimum_protocol_version        = "TLSv1.2_2021"
  }

  aliases = [
    "www.samuelalber.com",
    "samuelalber.com"
  ]
  /*
  Aliases attribute in the aws_cloudfront_distribution resource is mandatory if you want CloudFront to respond to custom domain names such as www.samuelalber.com and samuelalber.com.
  Without specifying the aliases, CloudFront will not recognize requests made to your custom domains and will only respond to requests made directly to the CloudFront domain (e.g., d1234567890.cloudfront.net).
   */

  depends_on = [aws_cloudfront_origin_access_control.oac]
}

# ------------------------- DynamoDB Table ------------------------- #

resource "aws_dynamodb_table" "viewer_count_table" {
  name         = "ViewerCountTable"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "counter_id"

  attribute {
    name = "counter_id"
    type = "S"
  }

  tags = {
    Name = "Viewer Count DynamoDB Table"
  }
}

# ------------------------- IAM Policies for Viewer Count Lambda ------------------------- #

# Policy for DynamoDB Access
resource "aws_iam_policy" "lambda_policy" {
  name        = "lambda_dynamodb_policy"
  description = "Allows Lambda to read/write to DynamoDB"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ],
        Resource = aws_dynamodb_table.viewer_count_table.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# ------------------------- Lambda Function for Viewer Count ------------------------- #

resource "aws_lambda_function" "viewer_count_function" {
  filename      = "viewer_count.zip"
  function_name = "viewer_count"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.viewer_count_table.name
    }
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_policy_attachment]
}

# ------------------------- API Gateway ------------------------- #

# Define the REST API
resource "aws_api_gateway_rest_api" "viewer_count_api" {
  name        = "ViewerCountAPI"
  description = "API Gateway for the Viewer Count Lambda function"
}

# Viewer Count Resource and Method
resource "aws_api_gateway_resource" "viewer_count_resource" {
  rest_api_id = aws_api_gateway_rest_api.viewer_count_api.id
  parent_id   = aws_api_gateway_rest_api.viewer_count_api.root_resource_id
  path_part   = "viewer-count"
}

resource "aws_api_gateway_method" "viewer_count_get" {
  rest_api_id   = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id   = aws_api_gateway_resource.viewer_count_resource.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id             = aws_api_gateway_resource.viewer_count_resource.id
  http_method             = aws_api_gateway_method.viewer_count_get.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.viewer_count_function.invoke_arn
}

# Lambda Permission for API Gateway
resource "aws_lambda_permission" "lambda_permission" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.viewer_count_function.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.viewer_count_api.execution_arn}/*/GET/viewer-count"

  depends_on = [
    aws_api_gateway_rest_api.viewer_count_api,
    aws_lambda_function.viewer_count_function
  ]
}

# Send CV Resource and Method
resource "aws_api_gateway_resource" "send_cv_resource" {
  rest_api_id = aws_api_gateway_rest_api.viewer_count_api.id
  parent_id   = aws_api_gateway_rest_api.viewer_count_api.root_resource_id
  path_part   = "send-cv"
}

resource "aws_api_gateway_method" "send_cv_method" {
  rest_api_id   = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id   = aws_api_gateway_resource.send_cv_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "send_cv_integration" {
  rest_api_id             = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id             = aws_api_gateway_resource.send_cv_resource.id
  http_method             = aws_api_gateway_method.send_cv_method.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.ses_lambda.invoke_arn
}

# Lambda Permission for SES Lambda
resource "aws_lambda_permission" "api_gateway_send_cv_permission" {
  statement_id  = "AllowAPIGatewayInvokeSES"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ses_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.viewer_count_api.execution_arn}/*/POST/send-cv"

  depends_on = [
    aws_api_gateway_rest_api.viewer_count_api,
    aws_lambda_function.ses_lambda
  ]
}

# API Deployment (remove 'stage_name' attribute)
resource "aws_api_gateway_deployment" "api_deployment" {
  depends_on = [
    aws_api_gateway_integration.lambda_integration,
    aws_api_gateway_integration.send_cv_integration,
    aws_api_gateway_method.viewer_count_options,
    aws_api_gateway_method.send_cv_options,
  ]
  rest_api_id = aws_api_gateway_rest_api.viewer_count_api.id
}

# API Gateway Stage (new resource)
resource "aws_api_gateway_stage" "prod" {
  stage_name    = "prod"
  rest_api_id   = aws_api_gateway_rest_api.viewer_count_api.id
  deployment_id = aws_api_gateway_deployment.api_deployment.id
}

# API Gateway Abuse Prevention (Optional) - Seems to now work... check. 
resource "aws_api_gateway_method_settings" "prod" {
  rest_api_id = aws_api_gateway_rest_api.viewer_count_api.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*" 
  # */* applies the specified method_settings to all methods (*) on all paths (*).
  # First * - For example, it applies to paths like /send-cv, 
  # /viewer-count, or even /some/other/resource. 

  # Second * (Wildcard for HTTP Method): For example, it applies to HTTP methods like GET, POST, PUT, DELETE, etc. 

   settings {
      throttling_rate_limit = 10
      throttling_burst_limit = 2
   }
}

// ViewerCount gate CORS

resource "aws_api_gateway_method" "viewer_count_options" {
  rest_api_id   = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id   = aws_api_gateway_resource.viewer_count_resource.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "viewer_count_cors" {
  rest_api_id             = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id             = aws_api_gateway_resource.viewer_count_resource.id
  http_method             = aws_api_gateway_method.viewer_count_options.http_method
  type                    = "MOCK"

  request_templates = {
    "application/json" = <<EOF
{
  "statusCode": 200 
}
EOF
// Otherwise we would need to write : "application/json" = "{\"statusCode\": 200}"
  }
}

/* Not supported for AWS_Proxy 

resource "aws_api_gateway_integration_response" "viewer_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id = aws_api_gateway_resource.viewer_count_resource.id
  http_method = aws_api_gateway_method.viewer_count_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
  }
    depends_on = [
    aws_api_gateway_resource.viewer_count_resource
    ]
}

Not supported for AWS_Proxy

resource "aws_api_gateway_method_response" "viewer_count_cors_response" {
  rest_api_id = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id = aws_api_gateway_resource.viewer_count_resource.id
  http_method = aws_api_gateway_method.viewer_count_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Headers" = true
  }
}
*/

// Send_CV gate CORS

resource "aws_api_gateway_method" "send_cv_options" {
  rest_api_id   = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id   = aws_api_gateway_resource.send_cv_resource.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "send_cv_cors" {
  rest_api_id             = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id             = aws_api_gateway_resource.send_cv_resource.id
  http_method             = aws_api_gateway_method.send_cv_options.http_method
  type                    = "MOCK"

  request_templates = {
    "application/json" = <<EOF
{
  "statusCode": 200
}
EOF
  }
}
/*Doesn't support AWS_PROXY

resource "aws_api_gateway_integration_response" "send_cv_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id = aws_api_gateway_resource.send_cv_resource.id
  http_method = aws_api_gateway_method.send_cv_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
    "method.response.header.Access-Control-Allow-Methods" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'" # Add POST for send-cv 
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
  }
  depends_on = [
    aws_api_gateway_resource.send_cv_resource
  ]

}

  Doesn't support AWS_PROXY

resource "aws_api_gateway_method_response" "send_cv_cors_response" {
  rest_api_id = aws_api_gateway_rest_api.viewer_count_api.id
  resource_id = aws_api_gateway_resource.send_cv_resource.id
  http_method = aws_api_gateway_method.send_cv_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Headers" = true
  }
}
*/
# ------------------------- End of main.tf ------------------------- #







