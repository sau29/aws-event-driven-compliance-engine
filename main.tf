terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "archive_file" "lambda_package" {
  type        = "zip"
  source_dir  = "${path.module}/python"
  output_path = "${path.module}/.terraform/lambda-package.zip"
}

locals {
  lambda_functions = {
    s3 = {
      name    = "s3_public_access_remediator"
      handler = "s3_public_access_remediator.lambda_handler"
    }
    iam = {
      name    = "iam_policy_guardrail_remediator"
      handler = "iam_policy_guardrail_remediator.lambda_handler"
    }
    security_group = {
      name    = "security_group_ingress_remediator"
      handler = "security_group_ingress_remediator.lambda_handler"
    }
    s3_encryption = {
      name    = "s3_encryption_remediator"
      handler = "s3_encryption_remediator.lambda_handler"
    }
  }
}

resource "aws_iam_role" "lambda" {
  for_each = local.lambda_functions
  name     = "${each.value.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  for_each   = aws_iam_role.lambda
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_remediation" {
  for_each = aws_iam_role.lambda
  role     = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      "Action" : [
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSecurityGroupRules",
        "ec2:RevokeSecurityGroupIngress",
        "iam:DetachGroupPolicy",
        "iam:DetachRolePolicy",
        "iam:DetachUserPolicy",
        "iam:ListRoleTags",
        "iam:ListUserTags",
        "s3:DeleteBucketPolicy",
        "s3:GetBucketPolicy",
        "s3:GetBucketTagging",
        "s3:GetEncryptionConfiguration",
        "s3:GetAccountPublicAccessBlock",
        "s3:GetBucketPublicAccessBlock",
        "s3:PutEncryptionConfiguration",
        "s3:PutBucketTagging",
        "s3:PutAccountPublicAccessBlock",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutObject",
        "s3:PutObjectTagging",
        "sns:Publish",
        "kms:Encrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
        "kms:ListAliases"
      ],
      Resource = "*"
    }]
  })
}

resource "aws_lambda_function" "remediator" {
  for_each = local.lambda_functions

  function_name    = each.value.name
  role             = aws_iam_role.lambda[each.key].arn
  handler          = each.value.handler
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_package.output_path
  source_code_hash = data.archive_file.lambda_package.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      ALERT_TOPIC_ARN   = module.remediation_engine.secops_alert_topic_arn
      AUDIT_BUCKET_NAME = module.audit_logging.audit_bucket_name
      KMS_KEY_ARN       = module.audit_logging.s3_compliance_kms_alias_arn
    }
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic]
}

module "compliance_rules" {
  source = "./modules/compliance_rules"

  aws_region = var.aws_region
}

module "audit_logging" {
  source = "./modules/audit_logging"

  aws_region         = var.aws_region
  bucket_name_prefix = var.audit_bucket_name_prefix
  retention_days     = var.audit_retention_days
  writer_role_arns   = [for role in aws_iam_role.lambda : role.arn]
}

module "remediation_engine" {
  source = "./modules/remediation_engine"

  aws_region                  = var.aws_region
  s3_compliance_kms_alias_arn = module.audit_logging.s3_compliance_kms_alias_arn

  s3_lambda_function_name  = aws_lambda_function.remediator["s3"].function_name
  iam_lambda_function_name = aws_lambda_function.remediator["iam"].function_name
  sg_lambda_function_name  = aws_lambda_function.remediator["security_group"].function_name

  s3_lambda_function_arn             = aws_lambda_function.remediator["s3"].arn
  iam_lambda_function_arn            = aws_lambda_function.remediator["iam"].arn
  sg_lambda_function_arn             = aws_lambda_function.remediator["security_group"].arn
  s3_encryption_lambda_function_name = aws_lambda_function.remediator["s3_encryption"].function_name
  s3_encryption_lambda_function_arn  = aws_lambda_function.remediator["s3_encryption"].arn

  alert_email_endpoints    = var.alert_email_endpoints
  chatbot_slack_channel_id = var.chatbot_slack_channel_id
  chatbot_slack_team_id    = var.chatbot_slack_team_id
}

check "required_detection_rules" {
  assert {
    condition = setunion(
      toset(module.compliance_rules.rule_names),
      toset([
        "s3-public-read-prohibited",
        "s3-encryption-customer-kms",
        "sg-restricted-incoming-traffic",
        "iam-policy-no-admin-access"
      ])
      ) == toset([
        "s3-public-read-prohibited",
        "s3-encryption-customer-kms",
        "sg-restricted-incoming-traffic",
        "iam-policy-no-admin-access"
    ])
    error_message = "All required AWS Config detection rules must be created."
  }
}

check "immutable_audit_vault" {
  assert {
    condition     = module.audit_logging.object_lock_mode == "COMPLIANCE" && module.audit_logging.object_lock_retention_days > 0
    error_message = "The audit vault must use positive Compliance-mode Object Lock retention."
  }
}

# 1. Create a brand-new, dedicated audit S3 bucket for CloudTrail
resource "aws_s3_bucket" "cloudtrail_audit_bucket" {
  bucket        = "saurabh-compliance-trail-audit-vault-2026"
  force_destroy = true

  tags = {
    Environment = "non-prod"
    Purpose     = "CloudTrail-Audit-Vault"
  }
}

# 2. Attach the required bucket policy so CloudTrail can write logs to it
resource "aws_s3_bucket_policy" "cloudtrail_audit_policy" {
  bucket = aws_s3_bucket.cloudtrail_audit_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_audit_bucket.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_audit_bucket.arn}/AWSLogs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# 3. Create the CloudTrail trail linked to the new bucket above
resource "aws_cloudtrail" "main_compliance_trail" {
  name                          = "event-engine-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_audit_bucket.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail_audit_policy]
}
