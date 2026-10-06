#!/usr/bin/env bash
set -Eeuo pipefail

spike_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stack_touched=0
server_pid=""

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if (( stack_touched )); then
        make -C "$spike_dir" destroy || status=1
    fi
    make -C "$spike_dir" local-down || status=1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_EC2_METADATA_DISABLED=true AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
endpoint="${AWS_ENDPOINT_URL:-http://localhost:4567}"
aws_local() { aws --endpoint-url "$endpoint" "$@"; }

make -C "$spike_dir" local-up
make -C "$spike_dir" package
make -C "$spike_dir" terraform-init
terraform -chdir="$spike_dir" validate
stack_touched=1
terraform -chdir="$spike_dir" apply -var-file=floci.tfvars -auto-approve -parallelism=1

api="$(terraform -chdir="$spike_dir" output -raw api_endpoint)"
python3 "$spike_dir/serve.py" --port 8080 --api-url "$api" >"${TMPDIR:-/tmp}/spike-3-site.log" 2>&1 &
server_pid=$!
for attempt in {1..20}; do
    if curl --silent --fail http://localhost:8080/ >/dev/null; then break; fi
    sleep 1
done
curl --fail --silent http://localhost:8080/ | grep -q 'Portrait Studio'
curl --fail --silent http://localhost:8080/config.js | grep -Fq 'apiBaseUrl: "/api"'
proxy_response="${TMPDIR:-/tmp}/spike-3-proxy-response.json"
proxy_status="$(curl --silent --show-error -o "$proxy_response" -w '%{http_code}' http://localhost:8080/api/jobs/not-a-real-job)"
[[ "$proxy_status" == 404 ]] && grep -Fq 'Job not found' "$proxy_response" || {
    echo "The local UI API proxy returned an unexpected response ($proxy_status)." >&2
    cat "$proxy_response" >&2
    exit 1
}
echo "Static site responds."

sample="${TMPDIR:-/tmp}/spike-3-e2e.png"
python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf4sAAAAASUVORK5CYII="))' > "$sample"
response="${TMPDIR:-/tmp}/spike-3-create.json"
curl --fail --silent --show-error "$api/jobs" \
    -H 'content-type: application/json' \
    --data "$(python3 -c 'import json,sys; print(json.dumps({"content_type":"image/png","size":len(open(sys.argv[1],"rb").read()),"prompt":"e2e portrait"}))' "$sample")" > "$response"
job_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["job_id"])' "$response")"
upload_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upload_url"])' "$response")"
echo "Job $job_id created; uploading test image."
upload_response="${TMPDIR:-/tmp}/spike-3-upload-response.txt"
upload_status="$(curl --silent --show-error -o "$upload_response" -w '%{http_code}' -X PUT -H 'content-type: image/png' --data-binary "@$sample" "$upload_url")"
[[ "$upload_status" == 200 ]] || { echo "S3 upload failed ($upload_status): $(cat "$upload_response")" >&2; exit 1; }
echo "Image uploaded; waiting for the worker."

for attempt in {1..60}; do
    status_json="$(curl --silent --show-error "$api/jobs/$job_id")"
    status="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$status_json")"
    if [[ "$status" == COMPLETED ]]; then break; fi
    if [[ "$status" == FAILED ]]; then echo "Worker failed: $status_json" >&2; exit 1; fi
    sleep 1
done
[[ "${status:-}" == COMPLETED ]] || { echo "Timed out waiting for completion: $status_json" >&2; exit 1; }
download="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["result_url"])' <<<"$status_json")"
result="${TMPDIR:-/tmp}/spike-3-result.png"
download_status="$(curl --silent --show-error --output "$result" --write-out '%{http_code}' "$download")"
[[ "$download_status" == 200 ]] || { echo "Result download failed ($download_status): $(cat "$result")" >&2; exit 1; }
cmp "$sample" "$result"
printf '\n========== SPIKE 3 E2E SUCCESS ==========\n'
printf 'Static page loaded; upload, S3 notification, SQS, Lambda, DynamoDB, and private result download completed for job %s.\n' "$job_id"
printf 'Floci used the deterministic image-copy backend; no model inference was called.\n'
printf '=========================================\n\n'
