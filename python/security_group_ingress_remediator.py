from typing import Any

import boto3

from common import alert_and_audit, environment_from_tags, event_detail, result


SENSITIVE_PORTS = {22, 23, 3389, 3306, 5432}


def open_sensitive_permissions(security_group: dict[str, Any]) -> list[dict[str, Any]]:
    permissions = []
    for permission in security_group.get("IpPermissions", []):
        from_port = permission.get("FromPort")
        to_port = permission.get("ToPort")
        if from_port is None or to_port is None:
            continue
        if not any(from_port <= port <= to_port for port in SENSITIVE_PORTS):
            continue
        if any(range_item.get("CidrIp") == "0.0.0.0/0" for range_item in permission.get("IpRanges", [])):
            permissions.append(permission)
    return permissions


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    detail = event_detail(event)
    request = detail.get("requestParameters", {})
    group_id = request.get("groupId") or request.get("groupIdSet", {}).get("items", [{}])[0].get("groupId")
    if not group_id:
        raise ValueError("Security Group ID was not present in the event")

    ec2 = boto3.client("ec2")
    group = ec2.describe_security_groups(GroupIds=[group_id])["SecurityGroups"][0]
    environment = environment_from_tags(group.get("Tags", []))
    open_permissions = open_sensitive_permissions(group)
    if open_permissions:
        ec2.revoke_security_group_ingress(GroupId=group_id, IpPermissions=open_permissions)
        outcome = (
            "auto-remediated: open sensitive-port ingress revoked"
            if environment == "non-prod"
            else "quarantined: open sensitive-port ingress revoked; alert emitted"
        )
    else:
        outcome = "no action: no open sensitive-port ingress found"

    resource_arn = f"arn:aws:ec2:{event.get('region', 'unknown')}:{event.get('account', 'unknown')}:security-group/{group_id}"
    record = alert_and_audit(event, "security-group-open-ingress", environment, outcome, resource_arn)
    return result(event, record)


lambda_handler = handler
