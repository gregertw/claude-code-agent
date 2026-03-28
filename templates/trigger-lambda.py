import json
import hmac
import os

import boto3

SHARED_SECRET = os.environ["SHARED_SECRET"]
INSTANCE_ID = os.environ["INSTANCE_ID"]
REGION = os.environ.get("REGION", "eu-north-1")


def lambda_handler(event, context):
    # Verify Bearer token
    headers = event.get("headers", {})
    token = headers.get("authorization", "")
    if not hmac.compare_digest(token, f"Bearer {SHARED_SECRET}"):
        return {"statusCode": 401, "body": json.dumps({"error": "unauthorized"})}

    # Check current instance state
    ec2 = boto3.client("ec2", region_name=REGION)
    resp = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    state = resp["Reservations"][0]["Instances"][0]["State"]["Name"]

    if state == "running":
        return {"statusCode": 200, "body": json.dumps({"status": "already_running"})}
    if state in ("stopping", "shutting-down", "terminated"):
        return {"statusCode": 409, "body": json.dumps({"status": "error", "message": f"Instance is {state}"})}

    # Start instance (boot-runner passes --force to orchestrator, bypassing hours guard)
    ec2.start_instances(InstanceIds=[INSTANCE_ID])
    return {"statusCode": 200, "body": json.dumps({"status": "starting"})}
