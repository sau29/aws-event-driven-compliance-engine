output "config_rule_names" {
  description = "AWS Config managed rule names."
  value       = module.compliance_rules.rule_names
}

output "config_rule_arns" {
  description = "AWS Config managed rule ARNs."
  value       = module.compliance_rules.rule_arns
}

output "remediation_eventbridge_rules" {
  description = "EventBridge rule names used by the remediation control plane."
  value = [
    module.remediation_engine.config_noncompliant_rule_name,
    module.remediation_engine.s3_policy_rule_name,
    module.remediation_engine.iam_policy_rule_name,
    module.remediation_engine.sg_ingress_rule_name
  ]
}

output "secops_alert_topic_arn" {
  description = "SNS topic ARN for SecOps alerts."
  value       = module.remediation_engine.secops_alert_topic_arn
}

output "audit_bucket_name" {
  description = "Immutable S3 evidence-vault bucket name."
  value       = module.audit_logging.audit_bucket_name
}

output "audit_bucket_arn" {
  description = "Immutable S3 evidence-vault bucket ARN."
  value       = module.audit_logging.audit_bucket_arn
}

output "config_delivery_bucket_name" {
  description = "S3 bucket used by AWS Config to deliver configuration history and snapshots."
  value       = module.compliance_rules.delivery_bucket_name
}

output "config_delivery_bucket_arn" {
  description = "ARN of the S3 bucket used by AWS Config delivery."
  value       = module.compliance_rules.delivery_bucket_arn
}

output "remediator_lambda_arns" {
  description = "Remediation Lambda function ARNs."
  value       = { for key, function in aws_lambda_function.remediator : key => function.arn }
}
