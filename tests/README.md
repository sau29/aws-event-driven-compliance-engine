# Test strategy

This folder is intended for validation of the compliance engine logic.

Suggested test coverage:

- Unit tests for policy evaluation functions
- Event simulation for S3, IAM, and EC2 non-compliance events
- Integration tests for EventBridge routing to Lambda
- Environment-aware remediation assertions
- Audit log verification

Use Moto for local AWS API simulation and expand to LocalStack or AWS sandbox validation when testing full event workflows.
