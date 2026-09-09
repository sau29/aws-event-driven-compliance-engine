from typing import Any
import boto3
from botocore.exceptions import ClientError

from common import alert_and_audit, environment_from_tags, event_detail, result

ADMIN_POLICY_ARN = "arn:aws:iam::aws:policy/AdministratorAccess"


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    detail = event_detail(event)
    request = detail.get("requestParameters", {})
    iam = boto3.client("iam")
    
    # Extract raw policy ARN from event request parameters
    raw_policy_arn = request.get("policyArn", "")
    policy_arn = raw_policy_arn if raw_policy_arn else ADMIN_POLICY_ARN

    # Determine target principal type and extract tags
    if request.get("roleName"):
        role_name = request["roleName"]
        tags = iam.list_role_tags(RoleName=role_name).get("Tags", [])
        principal_type = "role"
        resource_name = role_name
    elif request.get("userName"):
        user_name = request["userName"]
        tags = iam.list_user_tags(UserName=user_name).get("Tags", [])
        principal_type = "user"
        resource_name = user_name
    elif request.get("groupName"):
        group_name = request["groupName"]
        tags = iam.list_group_tags(GroupName=group_name).get("Tags", [])
        principal_type = "group"
        resource_name = group_name
    else:
        raise ValueError("IAM principal was not present in the event")

    environment = environment_from_tags(tags)
    
    # Verify if attached policy is AdministratorAccess
    is_admin = (
        policy_arn == ADMIN_POLICY_ARN 
        or policy_arn.endswith("/AdministratorAccess") 
        or "AdministratorAccess" in policy_arn
    )

    if not is_admin:
        outcome = "no action: attached policy is not an administrator policy"
    else:
        try:
            # Explicit calls eliminate parameter construction bugs
            if principal_type == "role":
                iam.detach_role_policy(RoleName=resource_name, PolicyArn=ADMIN_POLICY_ARN)
            elif principal_type == "user":
                iam.detach_user_policy(UserName=resource_name, PolicyArn=ADMIN_POLICY_ARN)
            elif principal_type == "group":
                iam.detach_group_policy(GroupName=resource_name, PolicyArn=ADMIN_POLICY_ARN)

            outcome = (
                "auto-remediated: unauthorized administrator policy detached"
                if environment == "non-prod"
                else "quarantined: unauthorized administrator policy detected; alert emitted"
            )
        except ClientError as e:
            if e.response["Error"]["Code"] == "NoSuchEntity":
                outcome = f"skipped: policy AdministratorAccess was already detached from {principal_type} {resource_name}"
            else:
                raise e

    record = alert_and_audit(event, "iam-admin-policy", environment, outcome, resource_name)
    return result(event, record)


lambda_handler = handler