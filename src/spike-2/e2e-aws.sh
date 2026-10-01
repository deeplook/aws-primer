#!/usr/bin/env bash
set -Eeuo pipefail

spike_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profile="${AWS_PROFILE:-}"

if [[ -z "$profile" ]]; then
    echo "Set AWS_PROFILE to an authenticated AWS profile." >&2
    exit 2
fi

make -C "$spike_dir" aws-target-check
make -C "$spike_dir" aws-apply AWS_PROFILE="$profile"

region="$(sed -n 's/^aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$spike_dir/aws.tfvars")"
bus="$(AWS_PROFILE="$profile" terraform -chdir="$spike_dir" output -raw event_bus_name)"
table="$(AWS_PROFILE="$profile" terraform -chdir="$spike_dir" output -raw orders_table_name)"
order_id="aws-primer-order-$(date +%s)-$$"
entries="$(ORDER_ID="$order_id" EVENT_BUS="$bus" python3 -c 'import json, os; detail={"order_id":os.environ["ORDER_ID"],"customer_id":"aws-e2e-customer","amount_cents":4200}; print(json.dumps([{"Source":"aws-primer.orders","DetailType":"OrderPlaced","Detail":json.dumps(detail),"EventBusName":os.environ["EVENT_BUS"]}]))')"
failed_entries="$(aws --profile "$profile" --region "$region" events put-events \
    --entries "$entries" \
    --query FailedEntryCount \
    --output text)"

if [[ "$failed_entries" != "0" ]]; then
    echo "EventBridge rejected $failed_entries event(s)." >&2
    exit 1
fi

for attempt in {1..90}; do
    status="$(aws --profile "$profile" --region "$region" dynamodb get-item \
        --table-name "$table" \
        --key "{\"order_id\":{\"S\":\"$order_id\"}}" \
        --query 'Item.status.S' \
        --output text 2>/dev/null || true)"
    amount="$(aws --profile "$profile" --region "$region" dynamodb get-item \
        --table-name "$table" \
        --key "{\"order_id\":{\"S\":\"$order_id\"}}" \
        --query 'Item.amount_cents.N' \
        --output text 2>/dev/null || true)"

    if [[ "$status" == "accepted" && "$amount" == "4200" ]]; then
        account_id="$(aws --profile "$profile" sts get-caller-identity --query Account --output text)"
        printf '\n========== AWS E2E SUCCESS ==========\n'
        printf 'EventBridge invoked Lambda, Step Functions ran, and order %s reached DynamoDB in account %s.\n' "$order_id" "$account_id"
        printf '=====================================\n\n'
        printf 'Resources are left running. Inspect the stack or destroy it with:\n'
        printf '  make -C src/spike-2 aws-destroy AWS_PROFILE=%s\n' "$profile"
        exit 0
    fi

    sleep 2
done

echo "AWS E2E timed out waiting for the processed order in DynamoDB." >&2
echo "Resources are left running for inspection; use aws-destroy when ready." >&2
exit 1
