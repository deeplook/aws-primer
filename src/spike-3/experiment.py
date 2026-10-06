#!/usr/bin/env python3
"""Run a single Stable Image Ultra image-to-image experiment."""

from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError


def generate_image(
    *,
    profile: str,
    region: str,
    model_id: str,
    image_path: Path,
    output_path: Path,
    prompt: str,
    strength: float,
) -> None:
    session = boto3.Session(profile_name=profile, region_name=region)
    bedrock = session.client(
        "bedrock-runtime",
        config=Config(
            connect_timeout=10,
            read_timeout=900,
            retries={"total_max_attempts": 2, "mode": "standard"},
        ),
    )
    source_image = base64.b64encode(image_path.read_bytes()).decode("ascii")
    request = {
        "prompt": prompt,
        "image": source_image,
        "strength": strength,
        "output_format": "png",
    }

    response = bedrock.invoke_model(
        modelId=model_id,
        body=json.dumps(request),
        contentType="application/json",
        accept="application/json",
    )
    result = json.loads(response["body"].read())
    images = result.get("images", [])
    if not images:
        raise RuntimeError(f"Bedrock returned no image: {result.get('finish_reasons')}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(base64.b64decode(images[0]))
    request_id = response.get("ResponseMetadata", {}).get("RequestId", "unknown")
    print(f"Generated image saved to {output_path} (Bedrock request {request_id}).")
    if result.get("finish_reasons", [None])[0] is not None:
        print(f"Model finish reason: {result['finish_reasons'][0]}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="dinu")
    parser.add_argument("--region", default="us-west-2")
    parser.add_argument("--model-id", default="stability.stable-image-ultra-v1:1")
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--output", default=Path("output/professional-portrait.png"), type=Path)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--strength", default=0.35, type=float)
    args = parser.parse_args()

    if not 0 <= args.strength <= 1:
        parser.error("--strength must be between 0.0 and 1.0")
    if not args.image.is_file():
        parser.error(f"input image does not exist: {args.image}")

    try:
        generate_image(
            profile=args.profile,
            region=args.region,
            model_id=args.model_id,
            image_path=args.image,
            output_path=args.output,
            prompt=args.prompt,
            strength=args.strength,
        )
        return 0
    except (BotoCoreError, ClientError, RuntimeError) as exc:
        print(f"Image generation failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
