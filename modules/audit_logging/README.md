# Audit Logging

This module provisions the immutable evidence vault for compliance decisions.

## Resources

- S3 bucket created with Object Lock enabled
- Default Object Lock retention in Compliance mode
- Versioning and public-access blocking
- TLS-only and SSE-KMS bucket policies
- Customer-managed KMS key with rotation enabled
- Optional write access for Lambda and EventBridge IAM roles

## Writer configuration

Pass the execution-role ARNs used by the remediation functions and EventBridge:

```hcl
writer_role_arns      = [aws_iam_role.remediation.arn]
eventbridge_role_arns = [aws_iam_role.eventbridge.arn]
```

The module exports the bucket policy and KMS policy JSON as well as the bucket and key ARNs. Store evidence under these prefixes:

- `evaluations/` for raw Config evaluations
- `remediation/` for enforcement outcomes
- `events/` for EventBridge metadata

Compliance-mode retention cannot be shortened or removed after objects are written. Use a sandbox bucket while validating the module.
