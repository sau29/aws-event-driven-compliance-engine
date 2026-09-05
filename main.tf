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
      Action = [
        "ec2:DescribeSecurityGroups",
        "ec2:RevokeSecurityGroupIngress",
        "iam:DetachGroupPolicy",
        "iam:DetachRolePolicy",
        "iam:DetachUserPolicy",
        "iam:ListGroupTags",
        "iam:ListRoleTags",
        "iam:ListUserTags",
        "s3:DeleteBucketPolicy",
        "s3:GetBucketTagging",
        "s3:PutPublicAccessBlock",
        "sns:Publish",
        "s3:PutObject",
        "s3:PutObjectTagging",
        "kms:Encrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey"
      ]
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

  aws_region = var.aws_region

  s3_lambda_function_name  = aws_lambda_function.remediator["s3"].function_name
  iam_lambda_function_name = aws_lambda_function.remediator["iam"].function_name
  sg_lambda_function_name  = aws_lambda_function.remediator["security_group"].function_name

  s3_lambda_function_arn  = aws_lambda_function.remediator["s3"].arn
  iam_lambda_function_arn = aws_lambda_function.remediator["iam"].arn
  sg_lambda_function_arn  = aws_lambda_function.remediator["security_group"].arn

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
        "sg-restricted-incoming-traffic",
        "iam-policy-no-admin-access"
      ])
      ) == toset([
        "s3-public-read-prohibited",
        "sg-restricted-incoming-traffic",
        "iam-policy-no-admin-access"
    ])
    error_message = "All three required AWS Config detection rules must be created."
  }
}

check "immutable_audit_vault" {
  assert {
    condition     = module.audit_logging.object_lock_mode == "COMPLIANCE" && module.audit_logging.object_lock_retention_days > 0
    error_message = "The audit vault must use positive Compliance-mode Object Lock retention."
  }
}
