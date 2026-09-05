# Code Understanding

## Readiness summary

This repository is an implementation scaffold and is **not yet ready for an unreviewed production deployment**. The main Terraform composition and Python handlers are present, but a real AWS sandbox validation is still required. The deployment also needs environment-specific IAM hardening, Lambda packaging verification, and confirmation that the selected AWS provider versions support every resource in the modules.

A safe first deployment target is a dedicated non-production AWS account. Do not apply the intentionally insecure fixture in production.

## Repository map

```text
.
|-- main.tf                         Root Terraform composition
|-- variables.tf                    Root deployment inputs
|-- outputs.tf                      Root deployment outputs
|-- requirements.txt                Local development and test dependencies
|-- README.md                       Architecture and project overview
|-- RUNBOOK.md                      Deployment and validation procedure
|-- code_understanding.md           This file
|-- modules/
|   |-- compliance_rules/           AWS Config detection layer
|   |-- remediation_engine/         EventBridge, Lambda targets, SNS, SSM
|   `-- audit_logging/              Object Lock S3 vault and KMS
|-- python/
|   |-- common.py                   Shared handler utilities
|   |-- s3_public_access_remediator.py
|   |-- iam_policy_guardrail_remediator.py
|   |-- security_group_ingress_remediator.py
|   `-- requirements.txt            Lambda runtime dependencies only
`-- examples/test_resources.tf       Isolated unsafe validation fixtures
```

Terraform only loads `.tf` files in the directory where the command is run. The root stack does not automatically load `examples/test_resources.tf`; deploy the fixture from a separate copied or linked test directory when intentionally creating violations.

## Root Terraform

### `main.tf`

The root composition creates the Lambda execution roles, packages the Python directory with `archive_file`, creates three Lambda functions, and instantiates the three modules.

- `data.archive_file.lambda_package`: creates one deployment ZIP containing the handlers and shared module.
- `aws_iam_role.lambda`: creates one execution role per remediator.
- `aws_iam_role_policy.lambda_remediation`: grants the remediation APIs, SNS publishing, audit writes, and KMS operations. This is intentionally broad for the scaffold and must be reduced before production.
- `aws_lambda_function.remediator`: deploys the three handlers and passes `ALERT_TOPIC_ARN` and `AUDIT_BUCKET_NAME`.
- `module.compliance_rules`: deploys AWS Config recording and managed rules.
- `module.audit_logging`: deploys the immutable evidence vault and allows the Lambda role ARNs to write to it.
- `module.remediation_engine`: deploys EventBridge, SNS, Chatbot, SSM, and Lambda target wiring.
- `check.required_detection_rules`: asserts that the three Config rules are exposed.
- `check.immutable_audit_vault`: asserts Compliance-mode Object Lock with positive retention.

### `variables.tf`

Defines region, audit-bucket prefix, retention, email recipients, and optional Slack Chatbot identifiers. Email and Chatbot are opt-in, but the audit bucket is still created.

### `outputs.tf`

Exports Config rule names and ARNs, EventBridge rule names, the SecOps SNS topic ARN, Lambda ARNs, the AWS Config delivery bucket name and ARN, and audit bucket identifiers.

## Detection module: `modules/compliance_rules`

### `main.tf`

- Creates a random-suffixed S3 delivery bucket for AWS Config.
- Enables bucket versioning, encryption, and public-access blocking.
- Creates the AWS Config service role and bucket policy.
- Creates `aws_config_delivery_channel` and `aws_config_configuration_recorder`.
- Enables recording through `aws_config_configuration_recorder_status`.
- Defines three AWS managed Config rules:
  - `s3-public-read-prohibited` using `S3_BUCKET_PUBLIC_READ_PROHIBITED`
  - `sg-restricted-incoming-traffic` using `RESTRICTED_INCOMING_TRAFFIC`
  - `iam-policy-no-admin-access` using `IAM_POLICY_NO_STATEMENTS_WITH_ADMIN_ACCESS`

The module accepts approved environment values as configuration metadata, but AWS Config managed rules themselves do not perform environment-aware remediation. The Lambda/SSM enforcement layer reads resource tags.

The Config delivery bucket is service infrastructure. It is separate from the random-suffixed audit bucket created by `modules/audit_logging`; the latter has Compliance-mode Object Lock and stores remediation evidence. Neither bucket is the intentionally non-compliant fixture.

### `variables.tf`

Defines region, delivery-bucket prefix, and the accepted environment values (`prod` and `non-prod`).

### `outputs.tf`

Exports the recorder name, delivery bucket name and ARN, managed rule names and ARNs, and accepted environment values. Config recorder and delivery-channel resources do not expose ARN attributes in the AWS provider, so no invalid recorder/channel ARN outputs are used.

## Remediation module: `modules/remediation_engine`

### `main.tf`

- `aws_cloudwatch_event_rule.config_noncompliant`: routes Config events with `newEvaluationResult=NON_COMPLIANT` for the three rule names.
- `aws_cloudwatch_event_rule.s3_policy_change`: routes S3 policy and ACL API events.
- `aws_cloudwatch_event_rule.iam_policy_attachment`: routes IAM policy attachment and inline policy writes.
- `aws_cloudwatch_event_rule.sg_ingress_change`: routes Security Group ingress authorization and rule modification events.
- `aws_cloudwatch_event_target.*`: sends matching events to the corresponding Lambda functions.
- `aws_cloudwatch_event_target.sg_policy_to_ssm`: sends Security Group events to the SSM Automation document.
- `aws_lambda_permission.*`: allows EventBridge to invoke the supplied Lambda functions.
- `aws_iam_role.eventbridge_ssm` and its policy: allow EventBridge to start the SSM Automation document.
- `aws_ssm_document.security_group_remediation`: describes Security Group validation, ingress revocation, and a final describe call.
- `aws_sns_topic.secops_alerts`: shared SecOps topic.
- `aws_sns_topic_subscription.email`: creates opt-in email subscriptions.
- `aws_chatbot_slack_channel_configuration.secops`: optionally connects the topic to a Slack channel when both Slack IDs are supplied.

The EventBridge SSM target uses a fixed `Environment=unknown` value because EventBridge input transformers cannot reliably select a tag from the CloudTrail request payload. The authoritative environment decision must therefore happen in the Lambda path or in a revised SSM workflow that fetches and validates resource tags before mutation.

### `variables.tf`

Accepts Lambda names and ARNs, SNS email addresses, and optional Chatbot identifiers.

### `outputs.tf`

Exports EventBridge rule names, the SSM document name/ARN, the SNS topic name/ARN, email subscription ARNs, and the optional `chatbot_configuration_arn`. The value comes from the AWS provider's `chat_configuration_arn` resource attribute and is `null` when Slack Chatbot is not configured.

## Audit module: `modules/audit_logging`

### `main.tf`

- `aws_kms_key.audit`: customer-managed KMS key with rotation and a policy for the account root plus configured writer roles.
- `aws_kms_alias.audit`: stable key alias.
- `aws_s3_bucket.audit`: creates the evidence bucket with Object Lock enabled at creation time.
- `aws_s3_bucket_versioning.audit`: enables versioning, required for Object Lock.
- `aws_s3_bucket_server_side_encryption_configuration.audit`: enforces SSE-KMS.
- `aws_s3_bucket_object_lock_configuration.audit`: sets default retention to Compliance mode.
- `data.aws_iam_policy_document.audit_bucket`: denies insecure transport and unencrypted uploads, and grants scoped object writes to configured roles.
- `aws_s3_bucket_public_access_block.audit`: blocks public access.

The module supports these evidence prefixes:

- `evaluations/`
- `remediation/`
- `events/`

Compliance-mode Object Lock is intentionally difficult to undo. Use a disposable sandbox bucket while testing.

### `variables.tf`

Defines bucket prefix, retention days, KMS settings, and Lambda/EventBridge writer role ARNs. Empty writer lists are allowed during module-only planning, but actual writers need to be supplied for end-to-end operation.

### `outputs.tf`

Exports bucket and KMS identifiers, recommended prefixes, policy JSON, and Object Lock settings.

## Python handlers

All handlers expose both `handler(event, context)` and `lambda_handler`, which matches the Terraform Lambda handler names.

### `common.py`

- `event_detail`: returns the EventBridge `detail` object or the event itself.
- `environment_from_tags`: requires an explicit `Environment` tag and accepts only `prod` or `non-prod`. Missing or unknown values fail closed.
- `resource_arn_from_event`: extracts common resource identifiers from event payloads.
- `account_and_region`: resolves account and region for notification records.
- `alert_and_audit`: creates the common notification/audit payload and optionally publishes to SNS and writes JSON to S3 when `ALERT_TOPIC_ARN` or `AUDIT_BUCKET_NAME` is set.
- `result`: returns a JSON Lambda response.

The payload fields are `account_id`, `region`, `resource_arn`, `violation_type`, `environment_tag`, `severity`, and `remediation_outcome`.

### `s3_public_access_remediator.py`

- `bucket_name_from_event`: extracts the bucket name from CloudTrail or Config-style payloads.
- `handler`: reads bucket tags. For non-prod it removes the bucket policy. For prod it enables all S3 public-access blocks, removes the policy, and records a quarantine alert.

### `iam_policy_guardrail_remediator.py`

- `ADMIN_POLICY_ARN`: identifies the AWS managed AdministratorAccess policy.
- `handler`: determines whether the event names a role, user, or group, reads its IAM tags, and detaches AdministratorAccess. The outcome distinguishes non-prod auto-remediation from prod quarantine/alert behavior.

### `security_group_ingress_remediator.py`

- `SENSITIVE_PORTS`: protects SSH, Telnet, RDP, MySQL, and PostgreSQL ports.
- `open_sensitive_permissions`: finds permissions containing `0.0.0.0/0` on a sensitive port.
- `handler`: describes the Security Group, reads its tags, revokes matching open permissions, and records the outcome.

## Local validation

### Python-only validation with Moto

Moto can simulate the Boto3 APIs used by the handlers without deploying AWS resources. It is suitable for unit tests of tag lookup, policy removal, policy detachment, ingress revocation, SNS publishing, and S3 audit writes.

Suggested setup:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

The root `requirements.txt` is the local development and test dependency set and includes Boto3, Moto, and pytest. The `python\requirements.txt` file contains only the Lambda runtime dependency set and should not be used for local test setup.

Recommended tests should use `@mock_aws` and assert real simulated resource state after each handler call. Cover both explicit environments:

- `Environment=non-prod`: resource becomes compliant automatically.
- `Environment=prod`: quarantine action and notification/audit record are produced.
- Missing or invalid `Environment`: handler fails closed and performs no mutation.

Moto does not reproduce the full EventBridge, Config, Lambda, Chatbot, or SSM service chain. Use LocalStack or an AWS sandbox for integration testing.

### Terraform-only local validation

Run these from the repository root after installing Terraform:

```powershell
terraform fmt -recursive -check
terraform init
terraform validate
terraform plan
```

The examples fixture must be validated from its own Terraform working directory after copying the fixture and adding any required variable values. Do not run it casually because it intentionally creates public access and administrator privileges.

After a root deployment, identify the two managed buckets with:

```powershell
$configBucket = terraform output -raw config_delivery_bucket_name
$auditBucket = terraform output -raw audit_bucket_name
```

Use the fixture outputs for test resources. Do not substitute either managed bucket into a test or tagging command.

## Open items before deployment

### Terraform and AWS integration

1. Run `terraform init`, `terraform validate`, and `terraform plan` with the pinned AWS provider.
2. Confirm the exact AWS provider schema for `aws_chatbot_slack_channel_configuration` and the SSM Automation EventBridge target.
3. Confirm the SSM document target input format starts an Automation execution correctly and that the document has an execution role with EC2 permissions.
4. Wire the EventBridge/SSM role into audit-vault writer permissions if EventBridge must write event metadata directly.
5. Replace Lambda `Resource = "*"` permissions with resource-scoped policies.
6. Add CloudWatch log retention, alarms, DLQs, retry policy, and Lambda concurrency controls.
7. Add a deployment state backend and environment separation for dev/test/prod.
8. Review Config global-resource recording and the required service-linked roles in each region.

### Python behavior

1. Add pytest tests using Moto for all three handlers and both environments.
2. Add tests for Config event payload shapes, CloudTrail event shapes, missing tags, missing resources, and idempotent retries.
3. Use deterministic audit object keys or an event ID to avoid duplicate records during retries.
4. Add structured logging and correlation IDs.
5. Confirm the S3 prod quarantine policy matches the intended business recovery process.
6. Decide whether prod IAM policies should be detached immediately or only quarantined pending approval.

### Runbook and operational controls

1. Keep Terraform/AWS CLI version checks, AWS identity verification, dependency installation, and Chatbot output verification synchronized with the root Terraform configuration.
2. Add explicit cleanup commands for non-prod test resources.
3. Add an approval and recovery procedure for Compliance-mode Object Lock data.
4. Document SNS email confirmation and Chatbot Slack authorization.
5. Document the required exception/allow-list model for approved IAM administrators.
6. Add expected CloudWatch, EventBridge, Config, SNS, SSM, and S3 evidence checks with example commands.
7. Update the runbook to distinguish local Moto tests, LocalStack integration tests, and real AWS sandbox tests.

## Deployment recommendation

The project is ready for the next engineering step, not for blind production deployment. First run Terraform validation, then deploy the root stack into a disposable AWS sandbox, deploy the fixture separately, verify each event and remediation path, and only then tighten IAM permissions and promote through controlled environments.
