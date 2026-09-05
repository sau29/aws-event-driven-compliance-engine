output "config_noncompliant_rule_name" {
  description = "EventBridge rule that routes AWS Config non-compliant findings."
  value       = aws_cloudwatch_event_rule.config_noncompliant.name
}

output "config_noncompliant_rule_arn" {
  description = "ARN for the AWS Config non-compliant EventBridge rule."
  value       = aws_cloudwatch_event_rule.config_noncompliant.arn
}

output "s3_policy_rule_name" {
  description = "EventBridge rule for S3 policy and ACL changes."
  value       = aws_cloudwatch_event_rule.s3_policy_change.name
}

output "iam_policy_rule_name" {
  description = "EventBridge rule for IAM policy attachment changes."
  value       = aws_cloudwatch_event_rule.iam_policy_attachment.name
}

output "sg_ingress_rule_name" {
  description = "EventBridge rule for Security Group ingress changes."
  value       = aws_cloudwatch_event_rule.sg_ingress_change.name
}

output "ssm_document_name" {
  description = "The SSM Automation document used for multi-step Security Group remediation."
  value       = aws_ssm_document.security_group_remediation.name
}

output "ssm_document_arn" {
  description = "ARN of the SSM Automation document used for Security Group remediation."
  value       = aws_ssm_document.security_group_remediation.arn
}

output "secops_alert_topic_name" {
  description = "Name of the SNS topic used for SecOps compliance alerts."
  value       = aws_sns_topic.secops_alerts.name
}

output "secops_alert_topic_arn" {
  description = "ARN of the SNS topic used for SecOps compliance alerts."
  value       = aws_sns_topic.secops_alerts.arn
}

output "alert_email_subscription_arns" {
  description = "SNS email subscription ARNs; recipients must confirm their subscriptions."
  value       = [for subscription in aws_sns_topic_subscription.email : subscription.arn]
}

output "chatbot_configuration_arn" {
  description = "ARN of the optional AWS Chatbot Slack channel configuration."
  value       = try(aws_chatbot_slack_channel_configuration.secops[0].chat_configuration_arn, null)
}
