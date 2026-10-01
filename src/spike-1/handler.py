import os

import boto3
from botocore.exceptions import ClientError


def handler(event, context):
    records = event.get("Records", [])
    s3 = boto3.client("s3", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))
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

    try:
        s3.list_objects_v2(Bucket=os.environ["OUTPUT_BUCKET"])
    except ClientError as error:
        code = error.response["Error"]["Code"]
        print(f"ungranted s3:ListBucket correctly denied: {code}")
    else:
        raise RuntimeError("IAM check failed: s3:ListBucket was not granted")

    return {"processed": len(records)}
