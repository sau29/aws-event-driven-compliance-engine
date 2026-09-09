import json
import sys
from pathlib import Path

import boto3
from moto import mock_aws

sys.path.insert(0, str(Path(__file__).parents[1] / "python"))

from s3_encryption_remediator import handler


ACCOUNT_ID = "123456789012"
REGION = "us-east-1"
BUCKET = "encryption-test-bucket"
KMS_ALIAS_ARN = f"arn:aws:kms:{REGION}:{ACCOUNT_ID}:alias/compliance-s3-key"


def event():
    return {
        "account": ACCOUNT_ID,
        "region": REGION,
        "detail": {
            "requestParameters": {"bucketName": BUCKET},
        },
    }


def create_bucket(s3, environment):
    s3.create_bucket(Bucket=BUCKET)
    s3.put_bucket_tagging(
        Bucket=BUCKET,
        Tagging={"TagSet": [{"Key": "Environment", "Value": environment}]},
    )


def create_compliance_key(kms):
    key_id = kms.create_key(Description="test compliance S3 key")["KeyMetadata"]["KeyId"]
    kms.create_alias(AliasName="alias/compliance-s3-key", TargetKeyId=key_id)
    return key_id


def set_encryption(s3, key_id):
    s3.put_bucket_encryption(
        Bucket=BUCKET,
        ServerSideEncryptionConfiguration={
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "aws:kms",
                    "KMSMasterKeyID": key_id,
                },
                "BucketKeyEnabled": True,
            }]
        },
    )


@mock_aws
def test_non_prod_aes256_bucket_is_remediated_with_customer_kms_key():
    s3 = boto3.client("s3", region_name=REGION)
    kms = boto3.client("kms", region_name=REGION)
    create_bucket(s3, "non-prod")
    s3.put_bucket_encryption(
        Bucket=BUCKET,
        ServerSideEncryptionConfiguration={
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}
            }]
        },
    )
    create_compliance_key(kms)

    response = handler(event(), None)

    configuration = s3.get_bucket_encryption(Bucket=BUCKET)["ServerSideEncryptionConfiguration"]
    default = configuration["Rules"][0]["ApplyServerSideEncryptionByDefault"]
    assert default["SSEAlgorithm"] == "aws:kms"
    assert default["KMSMasterKeyID"] == KMS_ALIAS_ARN
    assert configuration["Rules"][0]["BucketKeyEnabled"] is True
    assert "auto-remediated" in json.loads(response["body"])["remediation_outcome"]


@mock_aws
def test_prod_aes256_bucket_is_quarantined_without_encryption_change():
    s3 = boto3.client("s3", region_name=REGION)
    create_bucket(s3, "prod")
    s3.put_bucket_encryption(
        Bucket=BUCKET,
        ServerSideEncryptionConfiguration={
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}
            }]
        },
    )

    response = handler(event(), None)

    tags = {tag["Key"]: tag["Value"] for tag in s3.get_bucket_tagging(Bucket=BUCKET)["TagSet"]}
    assert tags["ComplianceStatus"] == "Quarantined"
    configuration = s3.get_bucket_encryption(Bucket=BUCKET)["ServerSideEncryptionConfiguration"]
    assert configuration["Rules"][0]["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"] == "AES256"
    assert "quarantined" in json.loads(response["body"])["remediation_outcome"]


@mock_aws
def test_bucket_with_expected_customer_key_is_left_unchanged():
    s3 = boto3.client("s3", region_name=REGION)
    kms = boto3.client("kms", region_name=REGION)
    create_bucket(s3, "non-prod")
    create_compliance_key(kms)
    set_encryption(s3, KMS_ALIAS_ARN)

    response = handler(event(), None)

    body = json.loads(response["body"])
    assert body["remediation_outcome"].startswith("no action")
    configuration = s3.get_bucket_encryption(Bucket=BUCKET)["ServerSideEncryptionConfiguration"]
    assert configuration["Rules"][0]["ApplyServerSideEncryptionByDefault"]["KMSMasterKeyID"] == KMS_ALIAS_ARN
