"""Submit one uploaded image to an already-deployed Spike 3 AWS stack."""

import argparse
import json
import mimetypes
import time
import urllib.error
import urllib.request
from pathlib import Path
from subprocess import check_output


def request(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return response.read(), response.headers.get_content_type()
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"HTTP {error.code}: {detail}") from error


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--prompt", default="Professional photo headshot of this person in a business suit standing alone in an elevator looking into the camera.")
    args = parser.parse_args()
    image = args.image.read_bytes()
    content_type = mimetypes.guess_type(args.image.name)[0] or "application/octet-stream"
    if content_type not in {"image/jpeg", "image/png"}:
        raise SystemExit("IMAGE must be a JPEG or PNG")
    api = check_output(["terraform", "-chdir=.", "output", "-raw", "api_endpoint"], text=True).strip()
    body = json.dumps({"content_type": content_type, "size": len(image), "prompt": args.prompt}).encode()
    created, _ = request(f"{api}/jobs", body, {"content-type": "application/json"})
    job = json.loads(created)
    request(job["upload_url"], image, {"content-type": content_type}, method="PUT")
    print(f"Started job {job['job_id']}; waiting for Stable Image Ultra...")
    for _ in range(180):
        payload, _ = request(f"{api}/jobs/{job['job_id']}")
        state = json.loads(payload)
        if state["status"] == "COMPLETED":
            output = Path("output") / f"{job['job_id']}.png"
            output.parent.mkdir(exist_ok=True)
            generated, _ = request(state["result_url"])
            output.write_bytes(generated)
            print(f"Generated portrait saved to {output}")
            print("The AWS stack remains deployed. Destroy it with make aws-destroy AWS_PROFILE=...")
            return
        if state["status"] == "FAILED":
            raise SystemExit(f"Portrait job failed: {state.get('error', 'unknown error')}")
        time.sleep(2)
    raise SystemExit("Timed out waiting for Bedrock image generation")


if __name__ == "__main__":
    main()
