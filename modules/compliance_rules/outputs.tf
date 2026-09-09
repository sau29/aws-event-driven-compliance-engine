output "config_recorder_name" {
  description = "Name of the AWS Config recorder."
  value       = aws_config_configuration_recorder.this.name
}

output "delivery_bucket_name" {
  description = "The S3 bucket used to store AWS Config delivery logs."
  value       = aws_s3_bucket.config_delivery.bucket
}

output "delivery_bucket_arn" {
  description = "ARN of the S3 bucket used to store AWS Config delivery logs."
  value       = aws_s3_bucket.config_delivery.arn
}

output "rule_names" {
  description = "AWS Config managed rule names created by this module."
  value = [
    aws_config_config_rule.s3_public_read_prohibited.name,
    aws_config_config_rule.s3_customer_managed_kms_encryption.name,
    aws_config_config_rule.sg_restricted_incoming_traffic.name,
    aws_config_config_rule.iam_policy_no_admin_access.name
  ]
}

output "rule_arns" {
  description = "AWS Config managed rule ARNs created by this module."
  value = [
    aws_config_config_rule.s3_public_read_prohibited.arn,
    aws_config_config_rule.s3_customer_managed_kms_encryption.arn,
    aws_config_config_rule.sg_restricted_incoming_traffic.arn,
    aws_config_config_rule.iam_policy_no_admin_access.arn
  ]
}

output "allowed_environment_tags" {
  description = "Environment tag values that are accepted by the compliance guardrails."
  value       = var.allowed_environment_tags
}
