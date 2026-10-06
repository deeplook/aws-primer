# AWS Primer

Small, runnable experiments for learning how AWS services fit together. The
infrastructure spikes target Floci locally or a real AWS account; Spike 3
starts with a direct Bedrock image-generation experiment. Code and notes live
beside each spike so you can follow a request through the system.

| Spike | Flow | Main ideas |
| --- | --- | --- |
| [0: S3 static website](src/spike-0/README.md) | S3 bucket → public static website | Bucket policies, public access settings, website hosting |
| [1: SQS to storage](src/spike-1/README.md) | SQS → Lambda → S3 and DynamoDB | Event source mappings, least privilege, SQS visibility timeout, and an IAM denial probe |
| [2: Order workflow](src/spike-2/README.md) | EventBridge → Lambda → Step Functions → Lambda → DynamoDB | Event routing, workflow execution, retries, and delivery dead-letter queues |
| [3: AI business portrait studio](src/spike-3/README.md) | Browser → private S3 → SQS → Lambda → Bedrock → private result | Presigned uploads, asynchronous image generation, expiring job records, and private delivery |

## What the spikes teach

- **Spike 0 — S3 static website:** bucket setup, public access policy, and
  serving a small website. It shows how S3 website hosting and an object read
  policy make content available to anonymous visitors.
- **Spike 1 — SQS worker:** asynchronous processing with Lambda and
  DynamoDB, least-privilege IAM, and at-least-once message delivery. It shows
  why retries can repeat writes and how an IAM denial probe checks a real
  permission boundary.
- **Spike 2 — Event workflow:** EventBridge routing, Step Functions
  orchestration, retries, and a delivery dead-letter queue. It distinguishes
  failure to deliver an event to a target from failure inside a workflow, and
  records an emulator limitation and its workaround.

Together, the spikes progress from hosting a page, to processing queued work,
to coordinating an event-driven workflow. Each README describes the behavior
the spike demonstrates and the limits of that experiment.

Spike 3 includes a direct Bedrock experiment and a local/AWS serverless portrait
application. Its local E2E uses a deterministic image-copy backend; AWS E2E
invokes Bedrock. See the [Spike 3 guide](src/spike-3/README.md).

These are teaching spikes, not production templates. Their READMEs explain
what each design demonstrates and what it leaves out, including delivery
semantics, idempotency, and Floci's service gaps.

## Run locally

You need Docker, Terraform (1.6 or later), AWS CLI, Python 3, and Make. No AWS
account or credentials are needed for the Floci targets; the scripts use test
credentials against the local endpoint.

```bash
make list
make SPIKE=spike-1 help
make SPIKE=spike-1 e2e
make SPIKE=spike-2 e2e
make SPIKE=spike-3 e2e
```

Each local E2E starts Floci, provisions the spike, exercises one message or
event, checks the resulting data, and cleans up the Terraform resources and
container. Spike 1 also invokes an IAM probe under the Lambda execution role.
Spike 3 checks the browser/API upload-to-download path with a deterministic
image stub. Floci's data directory is retained so you can inspect it or reset
it yourself.

## Pre-commit checks

Install the `pre-commit` tool, then enable the repository hook once per
checkout:

```bash
pre-commit install
```

The config runs `check-all` for all three infrastructure spikes, including Terraform formatting
and validation, Python syntax, and Bash syntax checks. CI runs those checks and
all three Floci E2E flows. CI does not deploy to AWS or need AWS credentials.

The default `plan`, `apply`, and `e2e` targets use Floci and test credentials.
Spike 1's AWS targets use a separately configured AWS profile and state:

```bash
cp src/spike-1/aws.tfvars.example src/spike-1/aws.tfvars
aws sso login --profile aws-primer
make SPIKE=spike-1 aws-plan AWS_PROFILE=aws-primer
make SPIKE=spike-1 aws-e2e AWS_PROFILE=aws-primer
```

For spike 2, copy its own AWS configuration and use the same targets:

```bash
cp src/spike-2/aws.tfvars.example src/spike-2/aws.tfvars
make SPIKE=spike-2 aws-plan AWS_PROFILE=aws-primer
make SPIKE=spike-2 aws-e2e AWS_PROFILE=aws-primer
```

Spike 3's AWS deployment and model invocation are documented in its
[guide](src/spike-3/README.md). AWS inference may incur charges.

AWS E2E leaves resources running for inspection and can incur charges. The
maintainer has run both AWS E2E flows locally; GitHub CI intentionally tests
Floci only. Each spike uses separate local and AWS Terraform state files. These
state files are local to one checkout, not shared team state. See
[Deploying spike 1 to AWS](docs/deploy-to-aws.md) and the
[spike 2 guide](src/spike-2/README.md) for setup, verification, and cleanup.
