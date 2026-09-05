variable "aws_region" {
  description = "AWS region for Config recording and rule evaluation."
  type        = string
  default     = "us-east-1"
}

variable "config_bucket_prefix" {
  description = "Prefix used for the delivery bucket created for AWS Config logs."
  type        = string
  default     = "aws-config-delivery"
}

variable "allowed_environment_tags" {
  description = "Environment tag values permitted for resources under this compliance module."
  type        = list(string)
  default     = ["prod", "non-prod"]
}
