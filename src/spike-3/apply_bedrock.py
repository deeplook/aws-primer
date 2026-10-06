"""Apply the local Floci stack with temporary credentials from an AWS CLI profile."""

import argparse
import json
import os
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, help="AWS CLI profile allowed to invoke Bedrock")
    args = parser.parse_args()

    exported = subprocess.run(
        ["aws", "configure", "export-credentials", "--profile", args.profile, "--format", "process"],
        check=True, capture_output=True, text=True,
    )
    credentials = json.loads(exported.stdout)
    required = ("AccessKeyId", "SecretAccessKey")
    if any(not credentials.get(key) for key in required):
        raise SystemExit("AWS profile did not export usable credentials.")

    env = os.environ.copy()
    env.update({
        "TF_VAR_local_image_backend": "bedrock",
        "TF_VAR_bedrock_access_key_id": credentials["AccessKeyId"],
        "TF_VAR_bedrock_secret_access_key": credentials["SecretAccessKey"],
        "TF_VAR_bedrock_session_token": credentials.get("SessionToken", ""),
    })
    module = Path(__file__).resolve().parent
    subprocess.run([
        "terraform", "-chdir=.", "apply", "-var-file=floci.tfvars",
        "-auto-approve", "-parallelism=1",
    ], cwd=module, env=env, check=True)
    print(f"Local Floci worker now uses Bedrock via AWS profile {args.profile}.")


if __name__ == "__main__":
    main()
