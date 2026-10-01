"""Check the output from a direct Lambda IAM probe invocation."""

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: assert_iam_probe.py <lambda-response.json>", file=sys.stderr)
        return 2

    result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    expected = {
        "probe": "list_bucket",
        "result": "denied",
        "error_code": "AccessDenied",
    }
    if result != expected:
        print(f"IAM denial probe failed: {result!r}", file=sys.stderr)
        return 1

    print("IAM probe passed: s3:ListBucket returned AccessDenied.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
