#!/usr/bin/env bash
set -Eeuo pipefail

spike_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
profile="${AWS_PROFILE:-}"

if [[ -z "$profile" ]]; then
    echo "Set AWS_PROFILE to an authenticated AWS profile." >&2
    exit 2
fi

make -C "$spike_dir" aws-target-check AWS_PROFILE="$profile"
make -C "$spike_dir" aws-terraform-init
terraform -chdir="$spike_dir" validate
AWS_PROFILE="$profile" terraform -chdir="$spike_dir" apply \
    -var-file=aws.tfvars -auto-approve

website_url="$(AWS_PROFILE="$profile" terraform -chdir="$spike_dir" output -raw website_url)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fetch_file() {
    local path="$1"
    local expected_type="$2"
    local output="$tmp_dir/${path##*/}"
    local headers="$tmp_dir/${path##*/}.headers"

    curl --fail --silent --show-error --max-time 30 \
        --dump-header "$headers" --output "$output" "$website_url/$path"
    grep -Eiq "^content-type: ${expected_type}" "$headers" || {
        echo "Unexpected Content-Type for $path" >&2
        cat "$headers" >&2
        return 1
    }
    test -s "$output" || { echo "Empty website response for $path" >&2; return 1; }
}

# curl has no AWS credentials here: these requests test anonymous public access.
fetch_file index.html 'text/html'
fetch_file style.css 'text/css'
fetch_file app.js 'text/javascript|application/javascript'
grep -q 'A website from an S3 bucket' "$tmp_dir/index.html"
grep -q 'color-scheme' "$tmp_dir/style.css"
grep -q 'Hello from JavaScript served by S3' "$tmp_dir/app.js"

printf '\n========== PUBLIC WEBSITE E2E SUCCESS ==========\n'
printf 'Anonymous HTTP GETs returned the HTML, CSS, and JavaScript from:\n%s\n' "$website_url"
printf '===============================================\n\n'
printf 'The public site remains deployed. To remove it and all bucket objects:\n'
printf '  make -C src/spike-0 aws-destroy AWS_PROFILE=%s\n' "$profile"
