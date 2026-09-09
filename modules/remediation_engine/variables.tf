variable "aws_region" {
  description = "AWS region in which the EventBridge control plane is deployed."
  type        = string
  default     = "us-east-1"
}

variable "s3_lambda_function_name" {
  description = "Name of the S3 remediation Lambda function."
  type        = string
  default     = "s3_public_access_remediator"
}

variable "iam_lambda_function_name" {
  description = "Name of the IAM remediation Lambda function."
  type        = string
  default     = "iam_policy_guardrail_remediator"
}

variable "sg_lambda_function_name" {
  description = "Name of the Security Group remediation Lambda function."
  type        = string
  default     = "security_group_ingress_remediator"
}

variable "s3_lambda_function_arn" {
  description = "ARN of the S3 remediation Lambda function."
  type        = string
}

variable "iam_lambda_function_arn" {
  description = "ARN of the IAM remediation Lambda function."
  type        = string
}

variable "sg_lambda_function_arn" {
  description = "ARN of the Security Group remediation Lambda function."
  type        = string
}

variable "s3_encryption_lambda_function_name" {
  description = "Name of the S3 encryption remediation Lambda function."
  type        = string
  default     = "s3_encryption_remediator"
}

variable "s3_encryption_lambda_function_arn" {
  description = "ARN of the S3 encryption remediation Lambda function."
  type        = string
}

variable "s3_compliance_kms_alias_arn" {
  description = "Regional customer-managed KMS alias used for S3 encryption remediation."
  type        = string
}

variable "sns_topic_name" {
  description = "Name of the SNS topic used for SecOps compliance alerts."
  type        = string
  default     = "secops-compliance-alerts"
}

variable "alert_email_endpoints" {
  description = "Email endpoints that receive compliance alerts through SNS. Each recipient must confirm the subscription."
  type        = list(string)
  default     = []
}

variable "chatbot_configuration_name" {
  description = "AWS Chatbot Slack channel configuration name."
  type        = string
  default     = "secops-compliance-alerts"
}

variable "chatbot_slack_channel_id" {
  description = "Slack channel ID for AWS Chatbot notifications. Set with chatbot_slack_team_id to enable Chatbot."
  type        = string
  default     = null
  nullable    = true
}

variable "chatbot_slack_team_id" {
  description = "Slack workspace/team ID for AWS Chatbot notifications. Set with chatbot_slack_channel_id to enable Chatbot."
  type        = string
  default     = null
  nullable    = true
}

