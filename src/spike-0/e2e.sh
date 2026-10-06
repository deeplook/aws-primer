#!/usr/bin/env bash
set -Eeuo pipefail

spike_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir=""

cleanup_tmp() {
    if [[ -n "$tmp_dir" ]]; then rm -rf "$tmp_dir"; fi
}
trap cleanup_tmp EXIT

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_EC2_METADATA_DISABLED=true
export AWS_CONFIG_FILE=/dev/null
export AWS_SHARED_CREDENTIALS_FILE=/dev/null
unset AWS_PROFILE

endpoint="${AWS_ENDPOINT_URL:-http://localhost:4566}"
make -C "$spike_dir" local-up
make -C "$spike_dir" terraform-init
terraform -chdir="$spike_dir" validate

terraform -chdir="$spike_dir" apply -var-file=floci.tfvars -auto-approve
website_url="$(terraform -chdir="$spike_dir" output -raw website_url)"
tmp_dir="$(mktemp -d)"

fetch_file() {
    local path="$1"
    local expected_type="$2"
    local output="$tmp_dir/${path##*/}"
    local headers="$tmp_dir/${path##*/}.headers"

    for attempt in {1..30}; do
        if curl --fail --silent --show-error --max-time 5 \
            --dump-header "$headers" --output "$output" "$website_url/$path" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    test -s "$output" || { echo "No public website response for $path at $website_url" >&2; return 1; }
    grep -Eiq "^content-type: ${expected_type}" "$headers" || {
        echo "Unexpected Content-Type for $path" >&2
        cat "$headers" >&2
        return 1
    }
}

# These unsigned requests prove the Floci S3 bucket policy allows public reads.
fetch_file index.html 'text/html'
fetch_file style.css 'text/css'
fetch_file app.js 'text/javascript|application/javascript'
grep -q 'A website from an S3 bucket' "$tmp_dir/index.html"
grep -q 'color-scheme' "$tmp_dir/style.css"
grep -q 'Hello from JavaScript served by S3' "$tmp_dir/app.js"

printf '\n========== FLOCI WEBSITE E2E SUCCESS ==========\n'
printf 'Anonymous HTTP GETs returned the HTML, CSS, and JavaScript from:\n%s\n' "$website_url"
printf 'The website and Floci are left running for inspection.\n'
printf 'Destroy the local S3 stack with: make SPIKE=spike-0 destroy\n'
printf 'Stop Floci afterward with: make SPIKE=spike-0 local-down\n'
printf '===============================================\n\n'
