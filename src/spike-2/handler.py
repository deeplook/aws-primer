import json
import os

import boto3


def starter(event, context):
    """Start the workflow with the complete EventBridge event."""
    stepfunctions = boto3.client(
        "stepfunctions", endpoint_url=os.environ.get("AWS_ENDPOINT_URL")
    )
    response = stepfunctions.start_execution(
        stateMachineArn=os.environ["STATE_MACHINE_ARN"],
        input=json.dumps(event),
    )
    execution_arn = response["executionArn"]
    print(f"started order workflow {execution_arn}")
    return {"execution_arn": execution_arn}


def handler(event, context):
    order = event["detail"]
    order_id = order["order_id"]
    amount_cents = int(order["amount_cents"])
    if amount_cents <= 0:
        raise ValueError("amount_cents must be positive")

    dynamodb = boto3.resource(
        "dynamodb", endpoint_url=os.environ.get("AWS_ENDPOINT_URL")
    )
    table = dynamodb.Table(os.environ["TABLE_NAME"])
    table.put_item(
        Item={
            "order_id": order_id,
            "customer_id": order["customer_id"],
            "amount_cents": amount_cents,
            "status": "accepted",
        }
    )
    print(f"accepted order {order_id}")
    return {"order_id": order_id, "status": "accepted"}
