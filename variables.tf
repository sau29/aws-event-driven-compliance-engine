variable "aws_region" {
  description = "AWS region for the compliance engine deployment."
  type        = string
  default     = "us-east-1"
}

variable "audit_bucket_name_prefix" {
  description = "Prefix for the immutable audit bucket."
  type        = string
  default     = "compliance-evidence-vault"
}

variable "audit_retention_days" {
  description = "Default Compliance-mode Object Lock retention period."
  type        = number
  default     = 1
}

variable "alert_email_endpoints" {
  description = "Email recipients for SecOps alerts."
  type        = list(string)
  default     = ["sau.agrawal@gmail.com"]
}

variable "chatbot_slack_channel_id" {
  description = "Optional Slack channel ID for AWS Chatbot."
  type        = string
  default     = null
  nullable    = true
}

variable "chatbot_slack_team_id" {
  description = "Optional Slack team ID for AWS Chatbot."
  type        = string
  default     = null
  nullable    = true
}
