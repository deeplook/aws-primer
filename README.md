# AWS Primer

Small, runnable Terraform experiments for learning how AWS services fit
together. Each spike can target Floci locally or a real AWS account. The
diagrams, Terraform, handlers, and end-to-end scripts are kept beside each
other so you can follow a request through the whole system.

| Spike | Flow | Main ideas |
| --- | --- | --- |
| [1: SQS to storage](src/spike-1/README.md) | SQS → Lambda → S3 and DynamoDB | Event source mappings, least privilege, SQS visibility timeout, and an IAM denial probe |
| [2: Order workflow](src/spike-2/README.md) | EventBridge → Lambda → Step Functions → Lambda → DynamoDB | Event routing, workflow execution, retries, and delivery dead-letter queues |

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
```

Each local E2E starts Floci, provisions the spike, exercises one message or
event, checks the resulting data, and cleans up the Terraform resources and
container. Spike 1 also invokes a separate IAM probe under the Lambda execution
role. Floci's data directory is retained locally so you can inspect it or reset
it yourself.

## Pre-commit checks

Install the `pre-commit` tool, then enable the repository hook once per
checkout:

```bash
pre-commit install
```

The config runs `check-all` for both spikes, including Terraform formatting
and validation, Python syntax, and Bash syntax checks. CI runs those checks and
both Floci E2E flows. CI does not deploy to AWS or need AWS credentials.

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

AWS E2E leaves resources running for inspection and can incur charges. The
maintainer has run both AWS E2E flows locally; GitHub CI intentionally tests
Floci only. Each spike uses separate local and AWS Terraform state files. These
state files are local to one checkout, not shared team state. See
[Deploying spike 1 to AWS](docs/deploy-to-aws.md) and the
[spike 2 guide](src/spike-2/README.md) for setup, verification, and cleanup.
