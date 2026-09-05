import json
import os
from datetime import datetime, timezone
from typing import Any

import boto3


ALLOWED_ENVIRONMENTS = {"prod", "non-prod"}


def event_detail(event: dict[str, Any]) -> dict[str, Any]:
    return event.get("detail", event)


def environment_from_tags(tags: list[dict[str, str]] | None) -> str:
    tag_map = {tag.get("Key"): tag.get("Value") for tag in tags or []}
    environment_value = tag_map.get("Environment")
    if not environment_value:
        raise ValueError("Resource must include an Environment tag")
    environment = environment_value.lower()
    if environment not in ALLOWED_ENVIRONMENTS:
        raise ValueError("Resource must have Environment=prod or Environment=non-prod")
    return environment


def resource_arn_from_event(event: dict[str, Any]) -> str | None:
    detail = event_detail(event)
    return (
        detail.get("resourceArn")
        or detail.get("resourceId")
        or detail.get("responseElements", {}).get("bucketName")
        or detail.get("requestParameters", {}).get("groupId")
    )


def account_and_region(event: dict[str, Any]) -> tuple[str, str]:
    return event.get("account", "unknown"), event.get("region", os.getenv("AWS_REGION", "unknown"))


def alert_and_audit(
    event: dict[str, Any],
    violation_type: str,
    environment: str,
    outcome: str,
    resource_arn: str | None,
) -> dict[str, Any]:
    account_id, region = account_and_region(event)
    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "account_id": account_id,
        "region": region,
        "resource_arn": resource_arn,
        "violation_type": violation_type,
        "environment_tag": environment,
        "severity": "CRITICAL" if environment == "prod" else "HIGH",
        "remediation_outcome": outcome,
    }

    topic_arn = os.getenv("ALERT_TOPIC_ARN")
    if topic_arn:
        boto3.client("sns", region_name=region).publish(
            TopicArn=topic_arn,
            Subject=f"Compliance remediation: {violation_type}",
            Message=json.dumps(record, default=str),
        )

    audit_bucket = os.getenv("AUDIT_BUCKET_NAME")
    if audit_bucket:
        key = f"remediation/{datetime.now(timezone.utc).strftime('%Y/%m/%d/%H%M%S')}-{violation_type}.json"
        boto3.client("s3", region_name=region).put_object(
            Bucket=audit_bucket,
            Key=key,
            Body=json.dumps(record, default=str).encode("utf-8"),
            ContentType="application/json",
        )

    return record


def result(event: dict[str, Any], record: dict[str, Any]) -> dict[str, Any]:
    return {"statusCode": 200, "body": json.dumps(record, default=str)}
