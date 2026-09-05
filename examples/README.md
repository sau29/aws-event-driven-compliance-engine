# Examples

This folder contains intentionally non-compliant Terraform test fixtures. It is separate from the root stack and must be deployed and destroyed explicitly.

Planned contents:
- intentionally non-compliant S3 bucket examples
- IAM policy test cases
- Security Group ingress examples
- validation test scenarios for non-prod and prod behavior

## Run the fixture

Run these commands from the repository root in a disposable AWS account. Use a globally unique S3 bucket name:

```powershell
$fixtureBucket = "compliance-test-$((Get-Random -Minimum 100000000 -Maximum 999999999))"
Push-Location examples
terraform init
terraform validate
terraform plan -var="test_bucket_name=$fixtureBucket" -out test-resources.tfplan
terraform apply test-resources.tfplan
terraform output
Pop-Location
```

The fixture tags its S3 bucket and IAM role as `Environment=non-prod` and its Security Group as `Environment=prod`. It does not use the root AWS Config delivery bucket or the Compliance-mode audit bucket.

Destroy the fixture when testing is complete:

```powershell
Push-Location examples
terraform destroy -var="test_bucket_name=$fixtureBucket"
Pop-Location
```
