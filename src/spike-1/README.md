# Spike 1: SQS, Lambda, S3, and DynamoDB

This Terraform spike connects SQS, Lambda, S3, DynamoDB, and IAM. Floci is the
default target and runs in Docker; it is not installed with `uv`. The same
Terraform resources can also target a real AWS account using an explicit AWS
configuration and separate Terraform state.

[Open the interactive data-flow diagram](.archify/dataflow-sqs-persistence-20261001-130013/sqs-message-dataflow.html)
for the SQS-to-Lambda-to-storage path and the worker role's permission scope.

[![SQS message data flow](.archify/dataflow-sqs-persistence-20261001-130013/sqs-message-dataflow.visual-check.1440x900.light.png)](.archify/dataflow-sqs-persistence-20261001-130013/sqs-message-dataflow.html)

IAM policy enforcement is enabled here; without that setting, Floci allows
requests regardless of the calling identity's policies. The AWS provider's
`test` credentials are a Floci bypass identity, so this experiment also checks
whether Lambda's execution role is evaluated under enforcement.

The probe passed with Floci 2.1.0: Terraform created the IAM role and policy,
S3 bucket, SQS queue, DynamoDB table, Lambda, and SQS event source mapping.
Lambda consumed an SQS message and wrote it to S3 and DynamoDB using its
execution role. The role grants `s3:PutObject` only under `processed/` and
`dynamodb:PutItem` only on the test table. With enforcement on, an ungranted
`s3:ListBucket` call was denied as expected. The initial run with enforcement
off allowed that call, as Floci documents.

From the repository root, run the local end-to-end check and cleanup. Spike 1
is selected by default:

```bash
make e2e
```

Use `make SPIKE=spike-2 help` to inspect the second spike's targets.

To inspect the local targets, use `make help`. `make apply` starts Floci,
packages the Lambda, and applies the local stack; `make destroy` removes the
Floci resources and leaves Floci running. `make local-down` stops Floci.

For AWS, copy `aws.tfvars.example` to `aws.tfvars`, set the account ID and
Region, authenticate an AWS CLI profile, then use `make aws-plan`,
`make aws-apply`, `make aws-e2e`, and `make aws-destroy`. These targets use a
separate AWS state file and never start Floci. AWS E2E leaves the stack running
so you can inspect it; empty its S3 bucket before running `aws-destroy`.
See the repository's [AWS deployment guide](../../docs/deploy-to-aws.md).

This is an integration probe, not proof of AWS parity. Check the Floci logs for
Lambda invocation output and record any unsupported API or behavioral gap.

Each spike's `terraform.tfvars` sets its local region and Floci endpoint URLs.
Terraform loads that file automatically; the Makefile also reads the host
endpoint and region from it for AWS CLI commands. The Lambda endpoint uses the
Docker service name so runtime containers can reach Floci.

The emulator stores state under `data/`; remove that directory only when you
want to reset this disposable local experiment.
