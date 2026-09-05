variable "aws_region" {
  description = "AWS region for the immutable audit vault."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name_prefix" {
  description = "Prefix for the Object Lock-enabled audit bucket."
  type        = string
  default     = "compliance-evidence-vault"
}

variable "retention_days" {
  description = "Default Compliance-mode Object Lock retention in days."
  type        = number
  default     = 365

  validation {
    condition     = var.retention_days > 0
    error_message = "retention_days must be greater than zero."
  }
}

variable "kms_alias_name" {
  description = "KMS alias name without the alias/ prefix."
  type        = string
  default     = "compliance-evidence-vault"
}

variable "kms_deletion_window_in_days" {
  description = "KMS key deletion waiting period."
  type        = number
  default     = 30
}

variable "writer_role_arns" {
  description = "IAM role ARNs used by Lambda remediation functions to write audit records."
  type        = list(string)
  default     = []
}

variable "eventbridge_role_arns" {
  description = "IAM role ARNs used by EventBridge or automation to write event metadata."
  type        = list(string)
  default     = []
}
