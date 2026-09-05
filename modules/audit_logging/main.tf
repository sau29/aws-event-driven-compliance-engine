terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "audit_key" {
  statement {
    sid    = "EnableRootAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = toset(var.writer_role_arns)

    content {
      sid    = "AllowAuditWriters${replace(element(split("/", statement.value), length(split("/", statement.value)) - 1), "-", "")}"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey"
      ]
      resources = ["*"]
    }
  }
}

resource "aws_kms_key" "audit" {
  description             = "KMS key for immutable compliance evidence"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.audit_key.json
}

resource "aws_kms_alias" "audit" {
  name          = "alias/${var.kms_alias_name}"
  target_key_id = aws_kms_key.audit.key_id
}

resource "random_string" "bucket_suffix" {
  length  = 8
  upper   = false
  special = false
  numeric = true
}

resource "aws_s3_bucket" "audit" {
  bucket              = "${var.bucket_name_prefix}-${random_string.bucket_suffix.result}"
  object_lock_enabled = true
  force_destroy       = false
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.audit.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.audit]
}

data "aws_iam_policy_document" "audit_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.audit.arn,
      "${aws_s3_bucket.audit.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyUnencryptedUploads"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  dynamic "statement" {
    for_each = toset(var.writer_role_arns)

    content {
      sid    = "AllowAuditObjectWrites${replace(element(split("/", statement.value), length(split("/", statement.value)) - 1), "-", "")}"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      actions = [
        "s3:AbortMultipartUpload",
        "s3:PutObject",
        "s3:PutObjectTagging"
      ]
      resources = ["${aws_s3_bucket.audit.arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = toset(var.writer_role_arns)

    content {
      sid    = "AllowAuditMultipartListing${replace(element(split("/", statement.value), length(split("/", statement.value)) - 1), "-", "")}"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      actions   = ["s3:ListBucketMultipartUploads"]
      resources = [aws_s3_bucket.audit.arn]
    }
  }

  dynamic "statement" {
    for_each = toset(var.eventbridge_role_arns)

    content {
      sid    = "AllowEventMetadataWrites${replace(element(split("/", statement.value), length(split("/", statement.value)) - 1), "-", "")}"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      actions   = ["s3:PutObject", "s3:PutObjectTagging"]
      resources = ["${aws_s3_bucket.audit.arn}/events/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket.json
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
