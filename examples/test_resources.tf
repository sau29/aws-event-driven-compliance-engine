terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "test_bucket_name" {
  description = "Globally unique bucket name for the non-prod S3 fixture."
  type        = string
}

variable "test_role_name" {
  type    = string
  default = "compliance-test-admin-role"
}

variable "test_security_group_name" {
  type    = string
  default = "compliance-test-prod-open-ssh"
}

resource "aws_s3_bucket" "noncompliant_public" {
  bucket        = var.test_bucket_name
  force_destroy = true

  tags = {
    Environment = "non-prod"
    TestCase    = "public-s3"
  }
}

resource "aws_s3_bucket_public_access_block" "noncompliant_public" {
  bucket                  = aws_s3_bucket.noncompliant_public.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "noncompliant_public" {
  bucket = aws_s3_bucket.noncompliant_public.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "public_bucket" {
  statement {
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.noncompliant_public.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "public" {
  bucket = aws_s3_bucket.noncompliant_public.id
  policy = data.aws_iam_policy_document.public_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.noncompliant_public]
}

resource "aws_iam_role" "admin" {
  name = var.test_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Environment = "non-prod"
    TestCase    = "iam-admin-policy"
  }
}

resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_security_group" "prod_open_ssh" {
  name        = var.test_security_group_name
  description = "Intentional non-compliant production fixture"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Environment = "non-prod"
    TestCase    = "open-ssh"
  }
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_vpc_security_group_ingress_rule" "open_ssh" {
  security_group_id = aws_security_group.prod_open_ssh.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

check "test_fixture_tags" {
  assert {
    condition     = aws_s3_bucket.noncompliant_public.tags.Environment == "non-prod"
    error_message = "The S3 fixture must be tagged Environment=non-prod."
  }

  assert {
    condition     = aws_iam_role.admin.tags.Environment == "non-prod"
    error_message = "The IAM fixture must be tagged Environment=non-prod."
  }

  assert {
    condition     = aws_security_group.prod_open_ssh.tags.Environment == "non-prod"
    error_message = "The Security Group fixture must be tagged Environment=prod."
  }
}

check "test_fixture_violations" {
  assert {
    condition     = aws_iam_role_policy_attachment.admin.policy_arn == "arn:aws:iam::aws:policy/AdministratorAccess"
    error_message = "The IAM fixture must attach AdministratorAccess."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.open_ssh.cidr_ipv4 == "0.0.0.0/0" && aws_vpc_security_group_ingress_rule.open_ssh.from_port == 22
    error_message = "The Security Group fixture must expose TCP/22 to 0.0.0.0/0."
  }
}

output "noncompliant_s3_bucket_arn" {
  value = aws_s3_bucket.noncompliant_public.arn
}

output "admin_role_arn" {
  value = aws_iam_role.admin.arn
}

output "prod_open_security_group_id" {
  value = aws_security_group.prod_open_ssh.id
}
