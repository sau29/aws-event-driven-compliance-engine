terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  config_noncompliant_event_rule_name = "config-noncompliant-remediation"
  s3_policy_event_rule_name           = "s3-policy-change-remediation"
  iam_policy_event_rule_name          = "iam-policy-attachment-remediation"
  sg_ingress_event_rule_name          = "sg-ingress-change-remediation"
}

resource "aws_sns_topic" "secops_alerts" {
  name = var.sns_topic_name
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_email_endpoints)

  topic_arn = aws_sns_topic.secops_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_iam_role" "chatbot" {
  count = var.chatbot_slack_channel_id != null && var.chatbot_slack_team_id != null ? 1 : 0
  name  = "secops-chatbot-notification-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "chatbot.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "chatbot_read_only" {
  count      = length(aws_iam_role.chatbot)
  role       = aws_iam_role.chatbot[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_chatbot_slack_channel_configuration" "secops" {
  count = var.chatbot_slack_channel_id != null && var.chatbot_slack_team_id != null ? 1 : 0

  configuration_name = var.chatbot_configuration_name
  iam_role_arn       = aws_iam_role.chatbot[0].arn
  slack_channel_id   = var.chatbot_slack_channel_id
  slack_team_id      = var.chatbot_slack_team_id
  sns_topic_arns     = [aws_sns_topic.secops_alerts.arn]
  logging_level      = "ERROR"
}

resource "aws_cloudwatch_event_rule" "config_noncompliant" {
  name        = local.config_noncompliant_event_rule_name
  description = "Routes AWS Config compliance failures to the remediation engine."

  event_pattern = jsonencode({
    source        = ["aws.config"],
    "detail-type" = ["Config Rules Compliance Change"],
    detail = {
      newEvaluationResult = ["NON_COMPLIANT"],
      configRuleName = [
        "s3-public-read-prohibited",
        "sg-restricted-incoming-traffic",
        "iam-policy-no-admin-access"
      ]
    }
  })
}

resource "aws_cloudwatch_event_rule" "s3_policy_change" {
  name        = local.s3_policy_event_rule_name
  description = "Routes S3 policy and ACL changes to the S3 remediation Lambda."

  event_pattern = jsonencode({
    source        = ["aws.s3"],
    "detail-type" = ["AWS API Call via CloudTrail"],
    detail = {
      eventSource = ["s3.amazonaws.com"],
      eventName   = ["PutBucketPolicy", "PutObjectAcl", "DeleteBucketPolicy"]
    }
  })
}

resource "aws_cloudwatch_event_rule" "iam_policy_attachment" {
  name        = local.iam_policy_event_rule_name
  description = "Routes IAM policy attachment events to the IAM remediation Lambda."

  event_pattern = jsonencode({
    source        = ["aws.iam"],
    "detail-type" = ["AWS API Call via CloudTrail"],
    detail = {
      eventSource = ["iam.amazonaws.com"],
      eventName = [
        "AttachUserPolicy",
        "AttachGroupPolicy",
        "AttachRolePolicy",
        "PutUserPolicy",
        "PutGroupPolicy",
        "PutRolePolicy"
      ]
    }
  })
}

resource "aws_cloudwatch_event_rule" "sg_ingress_change" {
  name        = local.sg_ingress_event_rule_name
  description = "Routes Security Group ingress changes to the SG remediation Lambda and SSM Automation."

  event_pattern = jsonencode({
    source        = ["aws.ec2"],
    "detail-type" = ["AWS API Call via CloudTrail"],
    detail = {
      eventSource = ["ec2.amazonaws.com"],
      eventName = [
        "AuthorizeSecurityGroupIngress",
        "ModifySecurityGroupRules"
      ]
    }
  })
}

resource "aws_lambda_permission" "config_noncompliant_s3" {
  statement_id  = "AllowEventBridgeToInvokeS3Remediator"
  action        = "lambda:InvokeFunction"
  function_name = var.s3_lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.config_noncompliant.arn
}

resource "aws_lambda_permission" "config_noncompliant_iam" {
  statement_id  = "AllowEventBridgeToInvokeIAMRemediator"
  action        = "lambda:InvokeFunction"
  function_name = var.iam_lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.config_noncompliant.arn
}

resource "aws_lambda_permission" "config_noncompliant_sg" {
  statement_id  = "AllowEventBridgeToInvokeSGRemediator"
  action        = "lambda:InvokeFunction"
  function_name = var.sg_lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.config_noncompliant.arn
}

resource "aws_lambda_permission" "s3_policy_change" {
  statement_id  = "AllowEventBridgeToInvokeS3PolicyRemediator"
  action        = "lambda:InvokeFunction"
  function_name = var.s3_lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_policy_change.arn
}

resource "aws_lambda_permission" "iam_policy_attachment" {
  statement_id  = "AllowEventBridgeToInvokeIAMPolicyRemediator"
  action        = "lambda:InvokeFunction"
  function_name = var.iam_lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.iam_policy_attachment.arn
}

resource "aws_lambda_permission" "sg_ingress_change" {
  statement_id  = "AllowEventBridgeToInvokeSGIngressRemediator"
  action        = "lambda:InvokeFunction"
  function_name = var.sg_lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sg_ingress_change.arn
}

resource "aws_cloudwatch_event_target" "config_to_s3_lambda" {
  rule      = aws_cloudwatch_event_rule.config_noncompliant.name
  target_id = "s3-remediation-lambda"
  arn       = var.s3_lambda_function_arn
}

resource "aws_cloudwatch_event_target" "config_to_iam_lambda" {
  rule      = aws_cloudwatch_event_rule.config_noncompliant.name
  target_id = "iam-remediation-lambda"
  arn       = var.iam_lambda_function_arn
}

resource "aws_cloudwatch_event_target" "config_to_sg_lambda" {
  rule      = aws_cloudwatch_event_rule.config_noncompliant.name
  target_id = "sg-remediation-lambda"
  arn       = var.sg_lambda_function_arn
}

resource "aws_cloudwatch_event_target" "s3_policy_to_lambda" {
  rule      = aws_cloudwatch_event_rule.s3_policy_change.name
  target_id = "s3-direct-policy-remediation"
  arn       = var.s3_lambda_function_arn
}

resource "aws_cloudwatch_event_target" "iam_policy_to_lambda" {
  rule      = aws_cloudwatch_event_rule.iam_policy_attachment.name
  target_id = "iam-direct-policy-remediation"
  arn       = var.iam_lambda_function_arn
}

resource "aws_cloudwatch_event_target" "sg_policy_to_lambda" {
  rule      = aws_cloudwatch_event_rule.sg_ingress_change.name
  target_id = "sg-direct-ingress-remediation"
  arn       = var.sg_lambda_function_arn
}

resource "aws_cloudwatch_event_target" "sg_policy_to_ssm" {
  rule      = aws_cloudwatch_event_rule.sg_ingress_change.name
  target_id = "sg-ssm-remediation"
  arn       = aws_ssm_document.security_group_remediation.arn
  role_arn  = aws_iam_role.eventbridge_ssm.arn

  input_transformer {
    input_paths = {
      group_id = "$.detail.requestParameters.groupId"
      region   = "$.region"
    }

    input_template = <<-EOT
      {
        "DocumentName": "SecurityGroupIngressQuarantineAndVerify",
        "Parameters": {
          "SecurityGroupId": [<group_id>],
          "Environment": ["unknown"],
          "Region": [<region>]
        }
      }
    EOT
  }
}

resource "aws_iam_role" "eventbridge_ssm" {
  name = "eventbridge-ssm-remediation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_ssm_execution" {
  name = "eventbridge-ssm-execution"
  role = aws_iam_role.eventbridge_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:StartAutomationExecution"
        ]
        Resource = [
          aws_ssm_document.security_group_remediation.arn
        ]
      }
    ]
  })
}

resource "aws_ssm_document" "security_group_remediation" {
  name          = "SecurityGroupIngressQuarantineAndVerify"
  document_type = "Automation"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Quarantine a Security Group with permissive ingress and validate the change."
    parameters = {
      SecurityGroupId = {
        type = "String"
      }
      Environment = {
        type    = "String"
        default = "unknown"
      }
      Region = {
        type = "String"
      }
    }
    mainSteps = [
      {
        name   = "CheckEnvironment",
        action = "aws:assertAwsResourceProperty",
        inputs = {
          Service          = "ec2",
          Api              = "DescribeSecurityGroups",
          PropertySelector = "$.SecurityGroups[0].GroupId",
          DesiredValues    = ["{{SecurityGroupId}}"]
        }
      },
      {
        name   = "RemediateIngress",
        action = "aws:executeAwsApi",
        inputs = {
          Service = "ec2",
          Api     = "RevokeSecurityGroupIngress",
          GroupId = "{{SecurityGroupId}}",
          IpPermissions = [
            {
              IpProtocol = "tcp",
              FromPort   = 22,
              ToPort     = 22,
              IpRanges   = [{ CidrIp = "0.0.0.0/0" }]
            }
          ]
        }
      },
      {
        name   = "ConfirmCompliance",
        action = "aws:executeAwsApi",
        inputs = {
          Service  = "ec2",
          Api      = "DescribeSecurityGroups",
          GroupIds = ["{{SecurityGroupId}}"]
        }
      }
    ]
  })
}
