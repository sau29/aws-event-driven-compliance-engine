import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

from common import alert_and_audit, environment_from_tags, event_detail, result


logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

ENCRYPTION_VIOLATION = "s3-customer-managed-kms-encryption"
KMS_ALIAS_NAME = "alias/compliance-s3-key"


def bucket_name_from_event(event: dict[str, Any]) -> str:
    detail = event_detail(event)
    request = detail.get("requestParameters", {})
    bucket_name = (
        request.get("bucketName")
        or detail.get("responseElements", {}).get("bucketName")
        or detail.get("resourceId")
    )
    if not bucket_name:
        raise ValueError("S3 bucket name was not present in the event")
    return bucket_name


def bucket_region_from_event(event: dict[str, Any]) -> str:
    detail = event_detail(event)
    return (
        event.get("region")
        or detail.get("awsRegion")
        or os.getenv("AWS_REGION", "us-east-1")
    )


def account_id_from_event(event: dict[str, Any], region: str) -> str:
    account_id = event.get("account") or event_detail(event).get("recipientAccountId")
    if account_id:
        return account_id
    return boto3.client("sts", region_name=region).get_caller_identity()["Account"]


def expected_kms_alias_arn(event: dict[str, Any], region: str) -> str:
    account_id = account_id_from_event(event, region)
    return f"arn:aws:kms:{region}:{account_id}:{KMS_ALIAS_NAME}"


def encryption_configuration(s3: Any, bucket_name: str) -> dict[str, Any] | None:
    try:
        return s3.get_bucket_encryption(Bucket=bucket_name).get("ServerSideEncryptionConfiguration")
    except ClientError as error:
        code = error.response.get("Error", {}).get("Code")
        if code in {"ServerSideEncryptionConfigurationNotFoundError", "NoSuchBucket"}:
            return None
        raise


def uses_expected_customer_key(
    s3: Any,
    kms: Any,
    bucket_name: str,
    configuration: dict[str, Any] | None,
    expected_alias_arn: str,
) -> bool:
    if not configuration:
        return False

    rules = configuration.get("Rules", [])
    if not rules:
        return False

    default = rules[0].get("ApplyServerSideEncryptionByDefault", {})
    if default.get("SSEAlgorithm") != "aws:kms":
        return False

    key_id = default.get("KMSMasterKeyID")
    if not key_id:
        return False

    key_metadata = kms.describe_key(KeyId=key_id)["KeyMetadata"]
    if key_metadata.get("KeyManager") != "CUSTOMER":
        return False

    aliases = kms.list_aliases(KeyId=key_metadata["KeyId"]).get("Aliases", [])
    return any(alias.get("AliasArn") == expected_alias_arn for alias in aliases)


def emit_metric(name: str, value: float = 1.0) -> None:
    metric = {
        "_aws": {
            "Timestamp": int(datetime.now(timezone.utc).timestamp() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": "ComplianceEngine",
                "Dimensions": [["Function", "ViolationType"]],
                "Metrics": [{"Name": name, "Unit": "Count"}],
            }],
        },
        "Function": "s3_encryption_remediator",
        "ViolationType": ENCRYPTION_VIOLATION,
        name: value,
    }
    logger.info(json.dumps(metric))


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    bucket_name = bucket_name_from_event(event)
    region = bucket_region_from_event(event)
    s3 = boto3.client("s3", region_name=region)
    kms = boto3.client("kms", region_name=region)
    tags = s3.get_bucket_tagging(Bucket=bucket_name).get("TagSet", [])
    environment = environment_from_tags(tags)
    resource_arn = f"arn:aws:s3:::{bucket_name}"
    expected_alias_arn = expected_kms_alias_arn(event, region)
    current_configuration = encryption_configuration(s3, bucket_name)

    if uses_expected_customer_key(s3, kms, bucket_name, current_configuration, expected_alias_arn):
        emit_metric("Compliant")
        logger.info("S3 bucket %s already uses %s", bucket_name, expected_alias_arn)
        record = alert_and_audit(
            event,
            ENCRYPTION_VIOLATION,
            environment,
            "no action: expected customer-managed KMS encryption is configured",
            resource_arn,
        )
        return result(event, record)

    emit_metric("NonCompliant")
    if environment == "non-prod":
        s3.put_bucket_encryption(
            Bucket=bucket_name,
            ServerSideEncryptionConfiguration={
                "Rules": [{
                    "ApplyServerSideEncryptionByDefault": {
                        "SSEAlgorithm": "aws:kms",
                        "KMSMasterKeyID": expected_alias_arn,
                    },
                    "BucketKeyEnabled": True,
                }]
            },
        )
        outcome = f"auto-remediated: customer-managed KMS encryption applied with {expected_alias_arn}"
        emit_metric("Remediated")
    else:
        s3.put_bucket_tagging(
            Bucket=bucket_name,
            Tagging={"TagSet": [*tags, {"Key": "ComplianceStatus", "Value": "Quarantined"}]},
        )
        outcome = "quarantined: S3 bucket tagged ComplianceStatus=Quarantined; alert emitted"
        emit_metric("Quarantined")

    record = alert_and_audit(event, ENCRYPTION_VIOLATION, environment, outcome, resource_arn)
    logger.info("S3 encryption remediation result: %s", record)
    return result(event, record)


lambda_handler = handler
