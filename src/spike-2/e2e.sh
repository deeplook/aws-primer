#!/usr/bin/env bash
set -Eeuo pipefail

spike_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_touched=0

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
order_id="order-$(date +%s)-$$"

aws_local() {
    aws --endpoint-url "$endpoint" "$@"
}

make -C "$spike_dir" local-up
make -C "$spike_dir" package
make -C "$spike_dir" terraform-init
terraform -chdir="$spike_dir" validate

# Provision the event workflow, then publish an OrderPlaced event.
stack_touched=1
terraform -chdir="$spike_dir" apply -var-file=floci.tfvars -auto-approve

bus="$(terraform -chdir="$spike_dir" output -raw event_bus_name)"
table="$(terraform -chdir="$spike_dir" output -raw orders_table_name)"
entries="$(ORDER_ID="$order_id" EVENT_BUS="$bus" python3 -c 'import json, os; detail={"order_id":os.environ["ORDER_ID"],"customer_id":"e2e-customer","amount_cents":4200}; print(json.dumps([{"Source":"aws-primer.orders","DetailType":"OrderPlaced","Detail":json.dumps(detail),"EventBusName":os.environ["EVENT_BUS"]}]))')"

failed_entries="$(aws_local events put-events \
    --entries "$entries" \
    --query FailedEntryCount \
    --output text)"
if [[ "$failed_entries" != "0" ]]; then
    echo "EventBridge rejected $failed_entries event(s)." >&2
    exit 1
fi

for attempt in {1..30}; do
    stored_status="$(aws_local dynamodb get-item \
        --table-name "$table" \
        --key "{\"order_id\":{\"S\":\"$order_id\"}}" \
        --query 'Item.status.S' \
        --output text 2>/dev/null || true)"
    stored_amount="$(aws_local dynamodb get-item \
        --table-name "$table" \
        --key "{\"order_id\":{\"S\":\"$order_id\"}}" \
        --query 'Item.amount_cents.N' \
        --output text 2>/dev/null || true)"

    # Pass only when the event reached the workflow and Lambda persisted the order.
    if [[ "$stored_status" == "accepted" && "$stored_amount" == "4200" ]]; then
        printf '\n========== E2E SUCCESS ==========\n'
        printf 'EventBridge invoked Lambda, Step Functions ran, and order %s reached DynamoDB.\n' "$order_id"
        printf '=================================\n\n'
        exit 0
    fi

    sleep 1
done

echo "E2E timed out waiting for the processed order in DynamoDB." >&2
make -C "$spike_dir" local-log-tail || true
exit 1
