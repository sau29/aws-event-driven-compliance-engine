output "audit_bucket_name" {
  description = "Name of the immutable compliance evidence bucket."
  value       = aws_s3_bucket.audit.bucket
}

output "audit_bucket_arn" {
  description = "ARN of the immutable compliance evidence bucket."
  value       = aws_s3_bucket.audit.arn
}

output "audit_bucket_object_prefixes" {
  description = "Recommended prefixes for evidence categories."
  value = {
    compliance_evaluations = "evaluations/"
    remediation_outcomes   = "remediation/"
    event_metadata         = "events/"
  }
}

output "audit_kms_key_arn" {
  description = "ARN of the KMS key used for audit-vault encryption."
  value       = aws_kms_key.audit.arn
}

output "audit_kms_alias_arn" {
  description = "ARN of the KMS alias used for audit-vault encryption."
  value       = aws_kms_alias.audit.arn
}

output "s3_compliance_kms_key_arn" {
  description = "ARN of the customer-managed KMS key used for compliant S3 encryption."
  value       = aws_kms_key.s3_compliance.arn
}

output "s3_compliance_kms_alias_arn" {
  description = "Regional alias ARN for compliant S3 encryption."
  value       = aws_kms_alias.s3_compliance.arn
}

output "audit_bucket_write_policy_json" {
  description = "Resource policy applied to the audit bucket for configured writer roles."
  value       = data.aws_iam_policy_document.audit_bucket.json
}

output "audit_kms_write_policy_json" {
  description = "KMS policy applied to the audit key for configured writer roles."
  value       = data.aws_iam_policy_document.audit_key.json
}

output "object_lock_mode" {
  description = "Default Object Lock retention mode."
  value       = "COMPLIANCE"
}

output "object_lock_retention_days" {
  description = "Default Object Lock retention period."
  value       = var.retention_days
}
