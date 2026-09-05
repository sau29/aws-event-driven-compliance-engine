from typing import Any

import boto3

from common import alert_and_audit, environment_from_tags, event_detail, result

ADMIN_POLICY_ARN = "arn:aws:iam::aws:policy/AdministratorAccess"


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    detail = event_detail(event)
    request = detail.get("requestParameters", {})
    iam = boto3.client("iam")
    policy_arn = request.get("policyArn", ADMIN_POLICY_ARN)
    resource_arn = request.get("roleName") or request.get("userName") or request.get("groupName")
    if not resource_arn:
        raise ValueError("IAM principal was not present in the event")

    if request.get("roleName"):
        tags = iam.list_role_tags(RoleName=request["roleName"]).get("Tags", [])
        principal_type = "role"
    elif request.get("userName"):
        tags = iam.list_user_tags(UserName=request["userName"]).get("Tags", [])
        principal_type = "user"
    else:
        tags = iam.list_group_tags(GroupName=request["groupName"]).get("Tags", [])
        principal_type = "group"

    environment = environment_from_tags(tags)
    is_admin = policy_arn == ADMIN_POLICY_ARN or policy_arn.endswith("/AdministratorAccess")
    if not is_admin:
        outcome = "no action: attached policy is not an administrator policy"
    else:
        detach = getattr(iam, f"detach_{principal_type}_policy")
        detach(**{f"{principal_type.capitalize()}Name": resource_arn, "PolicyArn": policy_arn})
        outcome = (
            "auto-remediated: unauthorized administrator policy detached"
            if environment == "non-prod"
            else "quarantined: unauthorized administrator policy detached; alert emitted"
        )

    record = alert_and_audit(event, "iam-admin-policy", environment, outcome, resource_arn)
    return result(event, record)


lambda_handler = handler
