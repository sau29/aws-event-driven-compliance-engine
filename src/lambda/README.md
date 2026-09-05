# Lambda remediation handlers

This directory contains the Lambda functions that enforce compliance logic.

Suggested modules:

- s3_public_access_remediator.py
- iam_admin_policy_guardrail.py
- security_group_ingress_remediator.py
- common/event_utils.py
- common/policy_evaluator.py

The core pattern is:

1. Parse AWS event payload
2. Determine resource and environment
3. Check if the resource violates a compliance rule
4. Auto-remediate in non-prod
5. Quarantine and notify in prod
6. Log the result to CloudWatch and the audit vault
