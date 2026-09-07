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
audit_retention_days  = 365
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

The `aws resourcegroupstaggingapi tag-resources` example previously shown in this runbook used `example-bucket` as a placeholder for an existing disposable resource. It did not refer to either Terraform-managed bucket. Do not tag the Config or Compliance-mode audit bucket as part of the fixture test.

## Deployment order
Follow this order to minimize drift and avoid broken event flows:

1. Prepare AWS account and environment tags
2. Create base IAM roles and trust policies
3. Deploy the detection layer
4. Deploy EventBridge routing
5. Deploy remediation functions and SSM automation
6. Configure alerting via SNS and Chatbot
7. Create the audit vault in S3 with WORM retention
8. Validate resource drift and events

## Deployment commands

Run these commands from the repository root in PowerShell. The first deployment should be performed in a dedicated sandbox account or non-production account.

```powershell
terraform fmt -recursive
terraform init
terraform validate
aws sts get-caller-identity
terraform plan -out compliance-engine.tfplan
terraform show -no-color compliance-engine.tfplan
terraform apply compliance-engine.tfplan
```

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

## Step 1: Define environment and tags
The test fixture creates and tags its own resources. Its S3 bucket and IAM role use `Environment=non-prod`; its Security Group uses `Environment=prod`. No manual tagging is required when deploying `examples/test_resources.tf`.

For an existing disposable sandbox resource that is not managed by this Terraform project, first set its real ARN and then apply tags. Replace the placeholder below; never use `example-bucket` literally:

```powershell
$testBucket = "saurabh-unique-disposable-bucket-name"
$testBucketArn = "arn:aws:s3:::$testBucket"

# 1. Create the S3 bucket
aws s3api create-bucket `
  --bucket $testBucket `
  --region us-east-1

# 2. Tag the bucket for non-prod auto-remediation
aws resourcegroupstaggingapi tag-resources `
  --resource-arn-list $testBucketArn `
  --tags Environment=non-prod,Owner=platform-team,Application=compliance-demo `
  --region us-east-1

# 3.To verify that the bucket was created and tagged properly:
  aws s3api get-bucket-tagging --bucket $testBucket --region us-east-1
```

For the Terraform-managed fixture, use the fixture output instead of manually tagging the bucket:

```powershell
$fixtureBucketArn = terraform -chdir=examples output -raw noncompliant_s3_bucket_arn
aws s3api get-bucket-tagging --bucket ($fixtureBucketArn -replace '^arn:aws:s3:::', '') --region us-east-1
```

# Sample output:
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
aws configservice describe-config-rules --config-rule-names s3-public-read-prohibited sg-restricted-incoming-traffic iam-policy-no-admin-access --region us-east-1
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
This step is manual and deliberately opt-in. The fixture is separate from the root stack so a normal root apply does not create unsafe resources.

Run the following commands from the repository root in PowerShell. Use the same AWS account and region where the root stack is deployed. The fixture creates three intentionally unsafe resources:

- S3 bucket and public-read bucket policy, tagged `Environment=non-prod`
- IAM role with `AdministratorAccess`, tagged `Environment=non-prod`
- Security Group with public TCP/22 ingress, tagged `Environment=prod`

Do not substitute the root `aws-config-delivery-*` or `compliance-evidence-vault-*` bucket names. The fixture creates a separate disposable bucket.

### 7.1 Deploy the fixture

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

Run these checks immediately after the fixture apply. They prove that the test resources were created in the intentionally non-compliant state before remediation runs:

```powershell
# S3: public policy exists and the bucket is tagged non-prod.
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

AWS Config evaluation and EventBridge delivery are asynchronous. Wait several minutes, then inspect the deployed rules, targets, and Lambda logs:

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

The expected result is that all three resources become compliant or restricted:

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

The fixture Security Group is tagged `Environment=prod`. The expected behavior is quarantine/revocation plus alerting, not silent approval. Verify the tag, ingress state, Lambda log, SNS topic activity, and audit object before considering the test complete:

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

Destroy the intentionally non-compliant fixture first:

```powershell
$fixtureBucketArn = terraform -chdir=examples output -raw noncompliant_s3_bucket_arn
$fixtureBucket = $fixtureBucketArn -replace '^arn:aws:s3:::', ''

Push-Location examples
terraform destroy -var="aws_region=us-east-1" -var="test_bucket_name=$fixtureBucket"
Pop-Location
```

Destroying the root stack removes the engine resources, but Compliance-mode audit objects can remain protected until their retention period expires. Plan audit-vault lifecycle and key deletion deliberately; do not use `force_destroy` for the audit vault.

```powershell
terraform destroy
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
