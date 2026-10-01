#!/usr/bin/env bash
set -Eeuo pipefail

spike_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profile="${AWS_PROFILE:-}"

if [[ -z "$profile" ]]; then
    echo "Set AWS_PROFILE to an authenticated AWS profile." >&2
    exit 2
fi

make -C "$spike_dir" aws-target-check
make -C "$spike_dir" aws-apply

region="$(sed -n 's/^aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$spike_dir/aws.tfvars")"
queue_url="$(AWS_PROFILE="$profile" terraform -chdir="$spike_dir" output -raw queue_url)"
bucket="$(AWS_PROFILE="$profile" terraform -chdir="$spike_dir" output -raw uploads_bucket_name)"
table="$(AWS_PROFILE="$profile" terraform -chdir="$spike_dir" output -raw processed_table_name)"
message_body="aws-primer-aws-e2e-$(date +%s)-$$"
message_id="$(aws --profile "$profile" --region "$region" sqs send-message \
    --queue-url "$queue_url" \
    --message-body "$message_body" \
    --query MessageId \
    --output text)"

for attempt in {1..60}; do
    stored_body="$(aws --profile "$profile" --region "$region" dynamodb get-item \
        --table-name "$table" \
        --key "{\"message_id\":{\"S\":\"$message_id\"}}" \
        --query 'Item.body.S' \
        --output text 2>/dev/null || true)"
    object_body="$(aws --profile "$profile" --region "$region" s3 cp \
        "s3://$bucket/processed/$message_id.txt" - \
        --no-progress 2>/dev/null || true)"

    if [[ "$stored_body" == "$message_body" && "$object_body" == "$message_body" ]]; then
        account_id="$(aws --profile "$profile" sts get-caller-identity --query Account --output text)"
        printf '\n========== AWS E2E SUCCESS ==========\n'
        printf 'SQS message %s reached Lambda, S3, and DynamoDB in account %s.\n' "$message_id" "$account_id"
        printf '=====================================\n\n'
        printf 'Resources are left running. To clean up, first empty s3://%s, then run:\n' "$bucket"
        printf '  make -C src/spike-1 aws-destroy AWS_PROFILE=%s\n' "$profile"
        exit 0
    fi

    sleep 2
done

echo "AWS E2E timed out waiting for the S3 object and DynamoDB item." >&2
echo "Resources are left running for inspection; use aws-destroy after cleanup." >&2
exit 1
