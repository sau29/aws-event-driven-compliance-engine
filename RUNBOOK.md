# Runbook: Deployment and Validation

## Purpose
This runbook explains how to deploy the AWS Event-Driven Compliance Engine locally or in a controlled AWS test environment and validate its behavior using intentionally non-compliant resources.

## Scope
This runbook focuses on the validation of:

- Public S3 bucket exposure
- Unauthorized IAM admin policy attachment
- Overly permissive Security Group ingress rules
- Event-driven remediation decisions in non-prod and prod environments

## Prerequisites
Before deployment, confirm the following:

- An AWS account or sandbox account with appropriate permissions
- Terraform 1.5 or newer installed and configured
- AWS CLI configured with a profile or access keys
- Python 3.12 or newer for local handler tests
- A unique S3 bucket name for the test fixture
- A confirmed SNS email address if email alerts are required
- Slack workspace and channel IDs if AWS Chatbot is required
- IAM permissions to create:
  - Config rules
  - EventBridge rules
  - Lambda functions
  - SNS topics
  - CloudWatch Logs groups
  - S3 buckets with retention or WORM policy
  - IAM roles and inline policies
- A working understanding of the target environment mapping:
  - Non-Prod = auto-remediate
  - Prod = quarantine + alert

### Local environment setup

Terraform and the AWS CLI are standalone tools; install them using the official installers for your operating system. Install the Python development and test libraries from the repository root:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

The `python\requirements.txt` file contains only the runtime dependency set used when packaging Lambda code. Do not install Moto or pytest into the Lambda deployment package.

Verify the installed tools and AWS identity before deployment:

```powershell
terraform version
aws --version
aws sts get-caller-identity
```

Terraform must satisfy the root configuration's `>= 1.5.0` constraint. Confirm that the reported AWS account and identity are the intended sandbox or non-production deployment target.

## Execution model

Terraform automates infrastructure creation and wiring. Human operators are still required to review the plan, confirm SNS email subscriptions, authorize Slack Chatbot, deploy the intentionally non-compliant fixture, inspect alerts, and approve any production recovery.

| Activity | Automated by Terraform | Manual operator action |
| --- | --- | --- |
| AWS Config, EventBridge, Lambda, SSM, SNS, KMS, and S3 resources | Yes | Review the plan and approve apply |
| Email alert delivery | Subscription is created | Confirm the SNS email subscription |
| Slack Chatbot delivery | Configuration is created when IDs are supplied | Authorize the Chatbot Slack workspace/channel |
| Non-prod remediation | Lambda/SSM performs it after an event | Review logs and final resource state |
| Prod quarantine and alert | Lambda/SSM performs the configured action | Investigate, approve recovery, and restore service |
| Non-compliant test resources | No, kept opt-in | Run the fixture commands deliberately |

The normal workflow is: **operator prepares inputs -> Terraform plans and deploys -> AWS services process events automatically -> operator validates evidence and outcomes**.

## Terraform variables

Create a local `terraform.tfvars` file in the repository root. Do not commit it if it contains operational email addresses or environment-specific values.

```hcl
aws_region            = "us-east-1"
audit_retention_days  = 1
alert_email_endpoints = ["secops@example.com"]

# Optional: set both values to enable AWS Chatbot.
chatbot_slack_channel_id = "C0123456789"
chatbot_slack_team_id    = "T0123456789"
```

Use an empty list for `alert_email_endpoints` and leave both Chatbot values `null` when those channels are not required.

## Bucket inventory

The root Terraform stack creates two S3 buckets. They have different owners and must not be used interchangeably:

| Bucket | Purpose | Safe operator action |
| --- | --- | --- |
| `aws-config-delivery-*` | AWS Config writes configuration history and snapshots here. | Do not make it public or use it as the audit destination. Inspect it with the commands below. |
| `compliance-evidence-vault-*` | Lambda writes compliance and remediation evidence here. Object Lock uses Compliance mode. | Do not delete, empty, or change retention on this bucket. |

After the root stack is deployed, retrieve the exact generated names instead of guessing the random suffix:

```powershell
$configBucket = terraform output -raw config_delivery_bucket_name
$auditBucket = terraform output -raw audit_bucket_name

Write-Host "AWS Config bucket: $configBucket"
Write-Host "Audit evidence bucket: $auditBucket"
aws s3api get-bucket-location --bucket $configBucket
aws s3api get-bucket-location --bucket $auditBucket
```

The optional tagging commands below apply only to existing disposable resources outside this Terraform project. Do not tag the Config delivery bucket or Compliance-mode audit bucket as fixture resources.

## Complete execution order

The root stack and the `examples` stack are separate Terraform working directories with separate state files. Run root-stack commands from the repository root and fixture commands from `examples`. Do not run `terraform apply` in one directory expecting resources from the other directory to be created.

1. Root stack: deploy the compliance engine
2. Examples stack: create intentionally non-compliant resources
3. AWS Config, EventBridge, Lambda, and SSM: detect and remediate them automatically
4. Verify logs, resource state, SNS, Config, and audit evidence
5. Destroy the examples fixture
6. Destroy the root stack when finished
7. Optional: tag an already-existing S3, Security Group, or IAM resource

Steps 1 and 2 are manual Terraform commands. Step 3 is performed automatically by AWS after the fixture creates a matching violation. Step 4 is manual verification. Steps 5 and 6 are manual cleanup commands. Step 7 is unrelated to the fixture and is only for existing resources outside these Terraform states.


## Root deployment commands

Run these commands from the repository root in PowerShell. These commands deploy the compliance engine only. They do not deploy `examples/test_resources.tf` and do not create intentionally non-compliant test resources.

| Command | Purpose | Required for root deployment? |
| --- | --- | --- |
| `terraform fmt -recursive` | Formats Terraform files. | Recommended local check; no AWS resources are changed. |
| `terraform init` | Downloads providers and initializes root Terraform state. | Yes, once per working directory or provider change. |
| `terraform validate` | Checks Terraform syntax and configuration. | Yes, before planning. |
| `aws sts get-caller-identity` | Confirms the AWS account and identity. | Yes, verify the target account before apply. |
| `terraform plan` | Previews root resources and changes. | Yes, review before apply. |
| `terraform apply` | Creates or updates the compliance engine. | Yes, only after plan approval. |

```powershell
terraform fmt -recursive
terraform init
terraform validate
aws sts get-caller-identity
terraform plan -out compliance-engine.tfplan
terraform show -no-color compliance-engine.tfplan
terraform apply compliance-engine.tfplan
```

This completes **Phase 1: root stack deployment**. It creates the compliance engine and its supporting resources, but it does not create test violations.

After `terraform apply`, the following root components are created automatically: AWS Config recorder and rules, the Config delivery bucket, the audit bucket, Lambda functions, EventBridge rules and targets, SNS, SSM Automation, IAM roles/policies, and optional Chatbot resources. The root apply does not simulate a violation.

Capture the deployed identifiers for later validation:

```powershell
terraform output
terraform output -raw secops_alert_topic_arn
terraform output -raw audit_bucket_name
terraform output -json config_rule_names
```

When Slack Chatbot is enabled, also inspect its optional module output:

```powershell
terraform output -raw chatbot_configuration_arn
```

The output is `null` when Chatbot is disabled. Internally, the AWS provider exposes this value as `chat_configuration_arn` on the `aws_chatbot_slack_channel_configuration` resource.

If the plan is not expected, stop before `terraform apply` and correct the variables or code. Terraform creates the compliance engine; it does not create the unsafe validation resources in `examples/`.

After this command completes, AWS Config, EventBridge, Lambda, and SSM detect and remediate the fixture automatically. Continue with the validation commands in Step 7 to inspect logs, resource state, SNS notifications, Config findings, and audit evidence.


## Optional phase: Tag existing resources

This phase is separate from the numbered fixture lifecycle. Execute it only after the compliance engine is deployed and only when testing an already-existing disposable resource outside this repository. Do not run it for the Terraform-managed fixture because `examples/test_resources.tf` applies the required tags automatically. Do not tag the AWS Config delivery bucket or Compliance-mode audit bucket as test resources.

Use this phase only for an already-existing disposable S3 bucket, Security Group, or IAM principal that is managed outside this repository. The resource must have an `Environment` tag with exactly `non-prod` or `prod`.

### Existing S3 bucket

```powershell
$region = "us-east-1"
$existingBucket = "replace-with-existing-disposable-bucket"

aws s3api get-bucket-location --bucket $existingBucket
aws resourcegroupstaggingapi tag-resources `
  --resource-arn-list "arn:aws:s3:::$existingBucket" `
  --tags Environment=non-prod,Owner=platform-team,Application=compliance-demo `
  --region $region
aws s3api get-bucket-tagging --bucket $existingBucket --region $region
```

### Existing Security Group

```powershell
$region = "us-east-1"
$existingGroupId = "sg-replace-me"

aws ec2 describe-security-groups --group-ids $existingGroupId --region $region
aws ec2 create-tags `
  --resources $existingGroupId `
  --tags Key=Environment,Value=non-prod Key=Owner,Value=platform-team `
  --region $region
aws ec2 describe-security-groups `
  --group-ids $existingGroupId `
  --query 'SecurityGroups[0].Tags' `
  --region $region
```

### Existing IAM role

```powershell
$existingRoleName = "replace-with-existing-disposable-role"

aws iam get-role --role-name $existingRoleName
aws iam tag-role `
  --role-name $existingRoleName `
  --tags Key=Environment,Value=non-prod Key=Owner,Value=platform-team
aws iam list-role-tags --role-name $existingRoleName
```

After tagging an existing resource, create a violation using the appropriate AWS CLI command in the validation section, then allow AWS Config and EventBridge to process it. Never use the root Config or audit buckets for this phase.

## Step 1: Define environment and tags
The test fixture creates and tags its own resources. Its S3 bucket and IAM role use `Environment=non-prod`; its Security Group uses `Environment=prod`. No manual tagging is required when deploying `examples/test_resources.tf`.

For the Terraform-managed fixture, use the fixture output to inspect its automatically applied tags; do not manually tag it:

```powershell
$fixtureBucketArn = terraform -chdir=examples output -raw noncompliant_s3_bucket_arn
aws s3api get-bucket-tagging --bucket ($fixtureBucketArn -replace '^arn:aws:s3:::', '') --region us-east-1
```

Sample output:
{                                                                                                          
    "TagSet": [
        {
            "Key": "Environment",
            "Value": "non-prod"
        },
        {
            "Key": "Application",
            "Value": "compliance-demo"
        },
        {
            "Key": "Owner",
            "Value": "platform-team"
        }                                                                                                  
    ]                                                                                                   
}     


For production, use:

```text
Environment=prod
```

These tags will drive the environment-aware enforcement logic.

The `Environment` tag is mandatory for remediation. Accepted values are exactly `non-prod` and `prod`; missing or invalid values fail closed.

## Step 2: Deploy the detection layer
This step is automated by `module.compliance_rules` during the root Terraform apply. AWS Config recording and the delivery channel are created before the managed rules are evaluated.

Example workflow:

1. Terraform creates the Config delivery bucket, recorder, delivery channel, and recorder status.
2. Terraform creates rules for:
  - public access checks
  - unrestricted Security Group ingress
  - IAM policy checks
3. Confirm the recorder is active and resource inventory captures relevant resources.

Inspect the deployed rules:

```powershell
aws configservice describe-configuration-recorder-status --region us-east-1

aws configservice describe-config-rules --config-rule-names iam-policy-no-admin-access --region us-east-1

aws configservice describe-config-rules --config-rule-names s3-public-read-prohibited --region us-east-1

aws configservice describe-config-rules --config-rule-names sg-restricted-incoming-traffic --region us-east-1
```

## Step 3: Deploy EventBridge control plane
This step is automated by `module.remediation_engine`. Terraform creates the Config non-compliance rule and the CloudTrail API-change rules, then connects them to the Lambda and SSM targets.

Example event patterns:

- S3 PutBucketPolicy
- S3 PutObjectAcl
- IAM AttachRolePolicy
- EC2 AuthorizeSecurityGroupIngress
- AWS Config non-compliance findings
- Security Hub / GuardDuty findings

Example rule concept:

```json
{
  "source": ["aws.config"],
  "detail-type": ["Config Rules Compliance Change"],
  "detail": {
    "configRuleName": ["s3-public-access-check"],
    "newEvaluationResult": ["NON_COMPLIANT"]
  }
}
```

Target the rule to a Lambda function or SSM automation document.

Inspect the EventBridge rules:

```powershell
aws events list-rules --name-prefix compliance --region us-east-1
aws events list-rules --name-prefix s3-policy --region us-east-1
aws events list-rules --name-prefix iam-policy --region us-east-1
aws events list-rules --name-prefix sg-ingress --region us-east-1
```

## Step 4: Deploy enforcement logic
This step is automated by the root `main.tf`, which packages `python/` and creates the three Lambda functions. SSM Automation is created by `module.remediation_engine`.

The Lambda deployment package contains the `python/` directory and uses only the runtime dependencies declared in `python\requirements.txt`. Root development dependencies such as Moto and pytest are for local testing and must not be packaged with Lambda.

### Lambda enforcement
Create Lambda functions for the most common remediation use cases:

- `s3_public_access_remediator`
- `iam_policy_guardrail_remediator`
- `security_group_ingress_remediator`

Each function should:

1. Read the event payload
2. Determine the resource ARN and environment tag
3. Evaluate if the violation is allowed or blocked
4. Apply the remediation path
5. Log the action and outcome
6. Emit a notification event

### SSM Automation
Use Systems Manager Automation when additional validation or multi-step enforcement is needed.

Typical use case:

- modify a Security Group
- confirm the change is effective
- reopen a ticket or notify the owner
- store evidence

## Step 5: Configure visibility and notifications
This step is automated by Terraform after notification inputs are supplied. Email recipients must manually confirm the SNS subscription, and Chatbot requires manual Slack authorization.

Example targets:

- Email
- SMS
- Slack via AWS Chatbot
- Teams via AWS Chatbot

Messages should include:

- account id
- region
- resource ARN
- violation type
- environment
- remediation action taken
- severity and next action

Confirm the SNS topic and subscriptions:

```powershell
$topicArn = terraform output -raw secops_alert_topic_arn
aws sns get-topic-attributes --topic-arn $topicArn --region us-east-1
aws sns list-subscriptions-by-topic --topic-arn $topicArn --region us-east-1
```

## Step 6: Create the audit vault
This step is automated by `module.audit_logging`. The bucket is created with Object Lock enabled and Compliance-mode default retention. This is irreversible for retained objects, so use a sandbox during testing.

Recommended controls:

- Object Lock enabled
- Versioning enabled
- Restrictive bucket policy
- Separate bucket for audit logs
- Lifecycle and retention policy for compliance evidence

This bucket should capture:

- evaluator output
- Lambda execution logs
- remediation actions
- event metadata and timestamps
- alert history

Verify the vault:

```powershell
$auditBucket = terraform output -raw audit_bucket_name
aws s3api get-object-lock-configuration --bucket $auditBucket --region us-east-1
aws s3api get-bucket-versioning --bucket $auditBucket --region us-east-1
aws s3api get-bucket-encryption --bucket $auditBucket --region us-east-1
```

## Step 7: Validation testing with non-compliant resources
This step is **manual, deliberately opt-in, and required only when you want to simulate violations**. The fixture is separate from the root stack so a normal root apply does not create unsafe resources. AWS Config, EventBridge, Lambda, and SSM perform detection and remediation automatically only after this fixture has been deployed and its violations exist.

Do not run this step in production. It creates public access, an administrator policy attachment, and public SSH ingress.

The public S3 test requires bucket-level S3 Block Public Access to be disabled for the disposable fixture. The fixture does this automatically. An account-level or organization-level policy that enforces `BlockPublicPolicy=true` cannot be overridden by Terraform; use a dedicated sandbox account where this test is permitted, or skip the public S3 scenario and test the IAM and Security Group scenarios instead.

Run the following commands from the repository root in PowerShell. Use the same AWS account and region where the root stack is deployed. The fixture creates three intentionally unsafe resources:

- S3 bucket and public-read bucket policy, tagged `Environment=non-prod`
- IAM role with `AdministratorAccess`, tagged `Environment=non-prod`
- Security Group with public TCP/22 ingress, tagged `Environment=prod`

Do not substitute the root `aws-config-delivery-*` or `compliance-evidence-vault-*` bucket names. The fixture creates a separate disposable bucket.

### 7.1 Deploy the fixture

This is the manual simulation trigger. Terraform creates the unsafe test resources and automatically applies their `Environment` tags. It does not deploy another compliance engine.

```powershell
$region = "us-east-1"
$fixtureBucket = "compliance-test-$((Get-Random -Minimum 100000000 -Maximum 999999999))"

Push-Location examples
terraform init
terraform validate
terraform plan -var="aws_region=$region" -var="test_bucket_name=$fixtureBucket" -out test-resources.tfplan
terraform apply test-resources.tfplan
terraform output
Pop-Location
```

Capture the resource identifiers for later commands:

```powershell
$fixtureBucketArn = terraform -chdir=examples output -raw noncompliant_s3_bucket_arn
$fixtureBucket = $fixtureBucketArn -replace '^arn:aws:s3:::', ''
$adminRoleArn = terraform -chdir=examples output -raw admin_role_arn
$adminRoleName = $adminRoleArn.Split('/')[-1]
$groupId = terraform -chdir=examples output -raw prod_open_security_group_id
$topicArn = terraform output -raw secops_alert_topic_arn
$auditBucket = terraform output -raw audit_bucket_name

Write-Host "Fixture bucket: $fixtureBucket"
Write-Host "IAM role: $adminRoleName"
Write-Host "Security Group: $groupId"
```

### 7.2 Confirm the initial violations

These commands are manual verification checks. Run them immediately after the fixture apply to prove that the resources were created in the intentionally non-compliant state before asynchronous remediation runs:

```powershell
# S3: public policy exists and the bucket is tagged non-prod.
aws s3api get-public-access-block --bucket $fixtureBucket --region $region
aws s3api get-bucket-policy --bucket $fixtureBucket --region $region
aws s3api get-bucket-tagging --bucket $fixtureBucket --region $region
aws s3api get-bucket-policy-status --bucket $fixtureBucket --region $region

# IAM: AdministratorAccess is attached to the fixture role.
aws iam list-attached-role-policies --role-name $adminRoleName
aws iam list-role-tags --role-name $adminRoleName

# EC2: the fixture Security Group exposes TCP/22 to the internet.
aws ec2 describe-security-groups --group-ids $groupId --region $region `
  --query 'SecurityGroups[0].IpPermissions'
```

### 7.3 Wait for detection and remediation

AWS Config evaluation and EventBridge delivery are automatic but asynchronous. Wait several minutes, then run these manual inspection commands:

```powershell
# Confirm the Config recorder is active.
aws configservice describe-configuration-recorder-status --region $region

# Confirm the three compliance rules exist.
aws configservice describe-config-rules `
  --config-rule-names s3-public-read-prohibited sg-restricted-incoming-traffic iam-policy-no-admin-access `
  --region $region

# Confirm EventBridge rules and targets exist.
aws events list-rules --name-prefix compliance --region $region
aws events list-rules --name-prefix s3-policy --region $region
aws events list-rules --name-prefix iam-policy --region $region
aws events list-rules --name-prefix sg-ingress --region $region
aws events list-targets-by-rule --rule config-noncompliant-remediation --region $region
aws events list-targets-by-rule --rule s3-policy-change-remediation --region $region
aws events list-targets-by-rule --rule iam-policy-attachment-remediation --region $region
aws events list-targets-by-rule --rule sg-ingress-change-remediation --region $region

# Review the three remediation Lambda log streams.
aws logs tail /aws/lambda/s3_public_access_remediator --since 30m --region $region
aws logs tail /aws/lambda/iam_policy_guardrail_remediator --since 30m --region $region
aws logs tail /aws/lambda/security_group_ingress_remediator --since 30m --region $region
```

If a log group is not present yet, the corresponding Lambda has not written a log event. Wait and run the command again. AWS Config and EventBridge delivery can take several minutes.

### 7.4 Verify the remediation result

Lambda and SSM perform the remediation automatically. Run these manual checks to verify that all three resources become compliant or restricted:

```powershell
# S3: the public bucket policy should be absent after non-prod remediation.
aws s3api get-bucket-policy --bucket $fixtureBucket --region $region
```

`get-bucket-policy` should return a `NoSuchBucketPolicy` error after the S3 remediator removes it. If it still returns a policy, inspect the S3 Lambda log and retry the check after waiting.

```powershell
# IAM: AdministratorAccess should no longer be attached.
aws iam list-attached-role-policies --role-name $adminRoleName

# EC2: no 0.0.0.0/0 TCP/22 ingress should remain.
aws ec2 describe-security-groups --group-ids $groupId --region $region `
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\` && ToPort==\`22\`]"
```

For Config evidence, query compliance after AWS Config has evaluated the resources:

```powershell
aws configservice describe-compliance-by-config-rule --region $region
aws configservice describe-compliance-by-resource `
  --resource-type AWS::S3::Bucket `
  --resource-id $fixtureBucket `
  --region $region
aws configservice describe-compliance-by-resource `
  --resource-type AWS::EC2::SecurityGroup `
  --resource-id $groupId `
  --region $region
```

Check notification and audit evidence:

```powershell
aws sns get-topic-attributes --topic-arn $topicArn --region $region
aws sns list-subscriptions-by-topic --topic-arn $topicArn --region $region
aws s3 ls "s3://$auditBucket/remediation/" --region $region
```

The IAM and Security Group remediation paths write audit records through the shared Lambda audit helper when `AUDIT_BUCKET_NAME` is configured. The S3 path also writes a record after removing or blocking public access.

### 7.5 Test the production decision path separately

The fixture Security Group is tagged `Environment=prod`. Remediation and alerting are automatic, while these commands manually verify the quarantine/revocation result:

```powershell
aws ec2 describe-security-groups --group-ids $groupId --region $region `
  --query 'SecurityGroups[0].Tags'
aws logs tail /aws/lambda/security_group_ingress_remediator --since 30m --region $region
aws s3 ls "s3://$auditBucket/remediation/" --region $region
```

The fixture itself is intentionally non-compliant, so AWS Config may report the original finding while the event-driven remediation is being processed. Use the resource-state checks above as the remediation check, then allow Config time to re-evaluate.

## Step 8: Validate events, remediation, and evidence

Use this final evidence check after the remediation commands in Step 7:

```powershell
$region = "us-east-1"
$fixtureBucketArn = terraform -chdir=examples output -raw noncompliant_s3_bucket_arn
$fixtureBucket = $fixtureBucketArn -replace '^arn:aws:s3:::', ''
$groupId = terraform -chdir=examples output -raw prod_open_security_group_id
$topicArn = terraform output -raw secops_alert_topic_arn
$auditBucket = terraform output -raw audit_bucket_name

aws configservice describe-compliance-by-config-rule --region $region
aws configservice describe-compliance-by-resource `
  --resource-type AWS::S3::Bucket `
  --resource-id $fixtureBucket `
  --region $region
aws configservice describe-compliance-by-resource --resource-type AWS::EC2::SecurityGroup --resource-id $groupId --region $region
aws logs tail /aws/lambda/s3_public_access_remediator --since 30m --region $region
aws logs tail /aws/lambda/iam_policy_guardrail_remediator --since 30m --region $region
aws logs tail /aws/lambda/security_group_ingress_remediator --since 30m --region $region
aws sns get-topic-attributes --topic-arn $topicArn --region $region
aws s3 ls "s3://$auditBucket/remediation/" --region $region
```

Confirm the checklist below for every scenario. For the `prod` Security Group, confirm quarantine and alert behavior rather than assuming full automatic recovery.

## Validation checklist
After each test, confirm the following:

- EventBridge rule fired
- AWS Config reported a non-compliant state
- Lambda or SSM function invoked the remediation path
- Correct environment logic executed
- Notification was sent via SNS / Chatbot
- Audit artifact was written to the S3 WORM vault
- Resource returned to a compliant state or was isolated in production

## Production behavior expectation
In production, the platform should not silently fix every issue. The expected path is:

1. detect violation
2. evaluate risk and environment
3. quarantine or restrict the resource
4. create alert and escalate
5. preserve immutable evidence
6. require review before full re-enablement

## Operational validation
Review the following logs and records:

- EventBridge execution history
- Lambda logs in CloudWatch Logs
- SNS delivery status
- Chatbot notifications
- S3 WORM vault evidence objects
- Config compliance timeline

## Rollback and recovery
If a remediation action is overly aggressive or an approved exception is required:

1. Remove the exception or override policy
2. Restore the original resource state from stored evidence or approved change history
3. Re-run the compliance check
4. Validate that the resource remains in a compliant baseline

## Cleanup

### Phase 5: Destroy the examples fixture

Destroy the intentionally non-compliant fixture first. This removes only resources managed by the `examples` state:

```powershell
$fixtureBucketArn = terraform -chdir=examples output -raw noncompliant_s3_bucket_arn
$fixtureBucket = $fixtureBucketArn -replace '^arn:aws:s3:::', ''

Push-Location examples
terraform destroy -var="aws_region=us-east-1" -var="test_bucket_name=$fixtureBucket"
Pop-Location
```

### Phase 6: Destroy the root stack


Destroying the root stack removes the engine resources, but Compliance-mode audit objects can remain protected until their retention period expires. Plan audit-vault lifecycle and key deletion deliberately; do not use `force_destroy` for the audit vault.

```powershell
# 1. Forget the locked S3 bucket from Terraform state tracking
terraform state rm module.audit_logging.aws_s3_bucket.audit

# 2. Forget the random suffix generator
terraform state rm module.audit_logging.random_string.bucket_suffix

# 3. Clean up any lingering state metadata
terraform destroy -auto-approve
```

## Exit criteria
The deployment is considered valid when:

- all detection rules are active
- event routing is functioning
- remediation logic matches environment policy
- alerts are visible to operators
- S3 WORM evidence is preserved
- non-compliant resources can be tested and recoverable without manual rebuilds

## Notes
This runbook is intentionally designed for test environments and controlled AWS validation. Do not execute the public-exposure test patterns against production resources without review and approval.
