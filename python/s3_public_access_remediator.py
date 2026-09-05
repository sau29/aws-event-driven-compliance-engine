from typing import Any

import boto3
from botocore.exceptions import ClientError

from common import alert_and_audit, environment_from_tags, event_detail, result


def bucket_name_from_event(event: dict[str, Any]) -> str:
    detail = event_detail(event)
    bucket_name = (
        detail.get("requestParameters", {}).get("bucketName")
        or detail.get("responseElements", {}).get("bucketName")
        or detail.get("resourceId")
    )
    if not bucket_name:
        raise ValueError("S3 bucket name was not present in the event")
    return bucket_name


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    bucket_name = bucket_name_from_event(event)
    s3 = boto3.client("s3")
    tags = s3.get_bucket_tagging(Bucket=bucket_name).get("TagSet", [])
    environment = environment_from_tags(tags)
    resource_arn = f"arn:aws:s3:::{bucket_name}"

    if environment == "non-prod":
        s3.delete_bucket_policy(Bucket=bucket_name)
        outcome = "auto-remediated: public bucket policy removed"
    else:
        s3.put_public_access_block(
            Bucket=bucket_name,
            PublicAccessBlockConfiguration={
                "BlockPublicAcls": True,
                "IgnorePublicAcls": True,
                "BlockPublicPolicy": True,
                "RestrictPublicBuckets": True,
            },
        )
        try:
            s3.delete_bucket_policy(Bucket=bucket_name)
        except ClientError as error:
            if error.response.get("Error", {}).get("Code") != "NoSuchBucketPolicy":
                raise
        outcome = "quarantined: S3 public access blocked; alert emitted"

    record = alert_and_audit(event, "s3-public-access", environment, outcome, resource_arn)
    return result(event, record)


lambda_handler = handler
