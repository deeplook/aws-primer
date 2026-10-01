import os

import boto3
from botocore.exceptions import ClientError


def handler(event, context):
    s3 = boto3.client("s3", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))

    if event.get("iam_probe") is True:
        try:
            s3.list_objects_v2(Bucket=os.environ["OUTPUT_BUCKET"])
        except ClientError as error:
            code = error.response.get("Error", {}).get("Code")
            if code != "AccessDenied":
                raise
            return {
                "probe": "list_bucket",
                "result": "denied",
                "error_code": code,
            }
        raise RuntimeError("IAM probe failed: s3:ListBucket was allowed")

    records = event.get("Records", [])
    dynamodb = boto3.resource(
        "dynamodb", endpoint_url=os.environ.get("AWS_ENDPOINT_URL")
    )
    table = dynamodb.Table(os.environ["TABLE_NAME"])
    for record in records:
        key = f"processed/{record['messageId']}.txt"
        message_body = record["body"]
        s3.put_object(
            Bucket=os.environ["OUTPUT_BUCKET"],
            Key=key,
            Body=message_body.encode(),
        )
        table.put_item(
            Item={"message_id": record["messageId"], "body": message_body}
        )
        print(f"stored SQS message at s3://{os.environ['OUTPUT_BUCKET']}/{key}")

    return {"processed": len(records)}
