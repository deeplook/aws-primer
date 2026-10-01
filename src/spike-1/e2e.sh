#!/usr/bin/env bash
set -Eeuo pipefail

spike_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_touched=0

# Always stop Floci; destroy Terraform resources if provisioning started.
cleanup() {
    status=$?
    trap - EXIT INT TERM

    if (( stack_touched )); then
        if ! make -C "$spike_dir" destroy; then
            status=1
        fi
    fi

    if ! make -C "$spike_dir" local-down; then
        status=1
    fi

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_EC2_METADATA_DISABLED=true
export AWS_CONFIG_FILE=/dev/null
export AWS_SHARED_CREDENTIALS_FILE=/dev/null

endpoint="${AWS_ENDPOINT_URL:-http://localhost:4566}"
queue_url="$endpoint/000000000000/aws-primer-local-jobs"
bucket="aws-primer-local-uploads"
table="aws-primer-local-processed"
message_body="aws-primer-e2e-$(date +%s)-$$"

aws_local() {
    aws --endpoint-url "$endpoint" "$@"
}

make -C "$spike_dir" local-up
make -C "$spike_dir" package
make -C "$spike_dir" terraform-init
terraform -chdir="$spike_dir" validate

# Provision the local stack, then send one uniquely named SQS message.
stack_touched=1
terraform -chdir="$spike_dir" apply -var-file=floci.tfvars -auto-approve

message_id="$(aws_local sqs send-message \
    --queue-url "$queue_url" \
    --message-body "$message_body" \
    --query MessageId \
    --output text)"

for attempt in {1..30}; do
    stored_body="$(aws_local dynamodb get-item \
        --table-name "$table" \
        --key "{\"message_id\":{\"S\":\"$message_id\"}}" \
        --query 'Item.body.S' \
        --output text 2>/dev/null || true)"
    object_size="$(aws_local s3api head-object \
        --bucket "$bucket" \
        --key "processed/$message_id.txt" \
        --query ContentLength \
        --output text 2>/dev/null || true)"

    # Pass only when Lambda copied the exact body to DynamoDB and S3.
    if [[ "$stored_body" == "$message_body" && "$object_size" == "${#message_body}" ]]; then
        printf '\n========== E2E SUCCESS ==========\n'
        printf 'SQS message %s reached Lambda, S3, and DynamoDB.\n' "$message_id"
        printf '=================================\n\n'
        exit 0
    fi

    sleep 1
done

echo "E2E timed out waiting for the S3 object and DynamoDB item." >&2
make -C "$spike_dir" local-log-tail || true
exit 1
