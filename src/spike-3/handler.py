"""HTTP API and SQS worker for the one-time portrait generation flow."""

import base64
import json
import os
import time
import urllib.parse
import uuid

import boto3
from botocore.config import Config


REGION = os.environ.get("AWS_REGION", "us-east-1")
ENDPOINT = os.environ.get("S3_ENDPOINT_URL") or None
PRESIGN_ENDPOINT = os.environ.get("S3_PRESIGN_ENDPOINT_URL") or ENDPOINT
BUCKET = os.environ["PORTRAITS_BUCKET"]
TABLE = os.environ["JOBS_TABLE"]
MAX_BYTES = int(os.environ.get("MAX_IMAGE_BYTES", "10485760"))
ALLOWED_TYPES = {"image/jpeg", "image/png"}
PROMPT_DEFAULT = "Professional photo headshot of this person in a business suit standing alone in an elevator looking into the camera."


class PermanentProcessingError(Exception):
    """An invalid or empty model result will not improve on an SQS retry."""


def _client(service, endpoint=None, config=None):
    return boto3.client(service, region_name=REGION, endpoint_url=endpoint, config=config)


def _table():
    return boto3.resource("dynamodb", region_name=REGION, endpoint_url=ENDPOINT).Table(TABLE)


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json; charset=utf-8", "cache-control": "no-store"},
        "body": json.dumps(body),
    }


def api_handler(event, _context):
    """Create a job or return its current status and a short-lived result URL."""
    route = event.get("routeKey", "")
    table = _table()
    if route == "POST /jobs":
        try:
            request = json.loads(event.get("body") or "{}")
            content_type = request.get("content_type", "image/jpeg").split(";")[0].lower()
            size = int(request.get("size", 0))
            prompt = (request.get("prompt") or PROMPT_DEFAULT).strip()
        except (ValueError, TypeError, json.JSONDecodeError):
            return _response(400, {"error": "Invalid request."})
        if content_type not in ALLOWED_TYPES or size < 1 or size > MAX_BYTES:
            return _response(400, {"error": "Use a JPEG or PNG image up to 10 MiB."})
        if not prompt or len(prompt) > 1000:
            return _response(400, {"error": "Prompt must contain 1 to 1000 characters."})

        job_id = str(uuid.uuid4())
        now = int(time.time())
        upload_key = f"uploads/{job_id}/input"
        table.put_item(Item={
            "job_id": job_id,
            "status": "UPLOADING",
            "prompt": prompt,
            "content_type": content_type,
            "created_at": now,
            "expires_at": now + int(os.environ.get("JOB_RETENTION_SECONDS", "86400")),
        })
        s3 = _client("s3", PRESIGN_ENDPOINT)
        upload_url = s3.generate_presigned_url(
            "put_object",
            Params={"Bucket": BUCKET, "Key": upload_key, "ContentType": content_type},
            ExpiresIn=int(os.environ.get("UPLOAD_URL_EXPIRY_SECONDS", "900")),
        )
        return _response(201, {"job_id": job_id, "status": "UPLOADING", "upload_url": upload_url,
                              "upload_content_type": content_type})

    if route.startswith("GET /jobs/"):
        job_id = (event.get("pathParameters") or {}).get("job_id", "")
        try:
            result = table.get_item(Key={"job_id": job_id}, ConsistentRead=True).get("Item")
        except Exception:
            return _response(500, {"error": "Could not read job status."})
        if not result:
            return _response(404, {"error": "Job not found or expired."})
        body = {"job_id": job_id, "status": result["status"]}
        if result["status"] == "FAILED":
            body["error"] = result.get("error", "Image processing failed.")
        if result["status"] == "COMPLETED":
            s3 = _client("s3", PRESIGN_ENDPOINT)
            body["result_url"] = s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": BUCKET, "Key": result["result_key"]},
                ExpiresIn=int(os.environ.get("DOWNLOAD_URL_EXPIRY_SECONDS", "300")),
            )
        return _response(200, body)

    return _response(404, {"error": "Route not found."})


def _bedrock_image(image_bytes, content_type, prompt):
    model_id = os.environ["BEDROCK_MODEL_ID"]
    request = {
        "prompt": prompt,
        "image": base64.b64encode(image_bytes).decode("ascii"),
        "strength": float(os.environ.get("IMAGE_STRENGTH", "0.75")),
        "output_format": "png",
    }
    credentials = {
        "aws_access_key_id": os.environ.get("BEDROCK_ACCESS_KEY_ID") or None,
        "aws_secret_access_key": os.environ.get("BEDROCK_SECRET_ACCESS_KEY") or None,
        "aws_session_token": os.environ.get("BEDROCK_SESSION_TOKEN") or None,
    }
    region = os.environ.get("BEDROCK_REGION", REGION)
    result = boto3.client(
        "bedrock-runtime",
        # Floci sets a global AWS_ENDPOINT_URL for its emulated services. An
        # explicit endpoint keeps model inference directed to Amazon Bedrock.
        endpoint_url=f"https://bedrock-runtime.{region}.amazonaws.com",
        region_name=region,
        config=Config(connect_timeout=10, read_timeout=280,
                      retries={"total_max_attempts": 1, "mode": "standard"}),
        **{key: value for key, value in credentials.items() if value},
    ).invoke_model(
        modelId=model_id,
        body=json.dumps(request),
        contentType="application/json",
        accept="application/json",
    )
    payload = json.loads(result["body"].read())
    if payload.get("error"):
        raise RuntimeError("Bedrock image generation failed")
    images = payload.get("images") or []
    if not images:
        reasons = payload.get("finish_reasons") or []
        fields = ",".join(sorted(payload)) or "none"
        reason = ",".join(str(item) for item in reasons) or "none"
        raise PermanentProcessingError(
            f"Bedrock returned no image (fields={fields}; finish_reasons={reason})."
        )
    return base64.b64decode(images[0])


def worker_handler(event, _context):
    """Process S3 upload notifications, safely acknowledging duplicate deliveries."""
    table = _table()
    s3 = _client("s3", ENDPOINT)
    failures = []
    for record in event.get("Records", []):
        message_id = record.get("messageId")
        job_id = None
        try:
            notification = json.loads(record["body"])
            if "Service" in notification and notification.get("Event") == "s3:TestEvent":
                continue
            for item in notification.get("Records", []):
                obj = item["s3"]["object"]
                key = urllib.parse.unquote_plus(obj["key"])
                if not key.startswith("uploads/") or not key.endswith("/input"):
                    continue
                job_id = key.split("/")[1]
                job = table.get_item(Key={"job_id": job_id}, ConsistentRead=True).get("Item")
                if not job or job["status"] in {"COMPLETED", "FAILED"}:
                    continue
                if job["status"] == "PROCESSING" and int(job.get("lease_until", 0)) > int(time.time()):
                    continue

                table.update_item(
                    Key={"job_id": job_id},
                    UpdateExpression="SET #s = :processing, lease_until = :lease",
                    ConditionExpression="#s = :uploading OR (#s = :processing AND lease_until <= :now)",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={":uploading": "UPLOADING", ":processing": "PROCESSING",
                                               ":lease": int(time.time()) + 1200, ":now": int(time.time())},
                )
                head = s3.head_object(Bucket=BUCKET, Key=key)
                if head["ContentLength"] > MAX_BYTES:
                    raise ValueError("Uploaded image exceeds the 10 MiB limit")
                image = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read(MAX_BYTES + 1)
                if len(image) > MAX_BYTES:
                    raise ValueError("Uploaded image exceeds the 10 MiB limit")
                if os.environ.get("IMAGE_BACKEND", "stub") == "stub":
                    generated = image
                else:
                    generated = _bedrock_image(image, job["content_type"], job["prompt"])
                result_key = f"results/{job_id}/portrait.png"
                s3.put_object(Bucket=BUCKET, Key=result_key, Body=generated,
                              ContentType="image/png", ServerSideEncryption="AES256")
                table.update_item(
                    Key={"job_id": job_id},
                    UpdateExpression="SET #s = :completed, result_key = :result REMOVE lease_until",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={":completed": "COMPLETED", ":result": result_key},
                )
        except Exception as error:  # Return partial failure so SQS retries and eventually DLQs it.
            receive_count = int(record.get("attributes", {}).get("ApproximateReceiveCount", "1"))
            permanent = isinstance(error, (KeyError, PermanentProcessingError))
            if job_id and (permanent or receive_count >= int(os.environ.get("MAX_RECEIVE_COUNT", "3"))):
                try:
                    table.update_item(
                        Key={"job_id": job_id},
                        UpdateExpression="SET #s = :failed, error = :error REMOVE lease_until",
                        ExpressionAttributeNames={"#s": "status"},
                        ExpressionAttributeValues={":failed": "FAILED", ":error": "Image processing failed after retries."},
                    )
                except Exception:
                    pass
            failure = {"level": "ERROR", "message": "portrait job processing failed",
                       "error_type": type(error).__name__, "message_id": message_id}
            if isinstance(error, KeyError):
                failure["missing_key"] = str(error.args[0]) if error.args else "unknown"
            if isinstance(error, PermanentProcessingError):
                failure["reason"] = str(error)
            print(json.dumps(failure))
            if message_id and not permanent:
                failures.append({"itemIdentifier": message_id})
    return {"batchItemFailures": failures}
