# Deploying spike 1 to AWS

Spike 1 connects SQS → Lambda → S3 and DynamoDB. It defaults to local Floci;
an explicit AWS target is also available. The maintainer has run the AWS E2E
flow locally. GitHub CI uses Floci and does not need AWS credentials; passing
the local AWS run is evidence for this configuration and account, not a
continuously repeated AWS deployment.

## Configure an AWS account

Copy the example configuration and set the intended account ID and Region:

```bash
cp src/spike-1/aws.tfvars.example src/spike-1/aws.tfvars
```

`aws.tfvars` is ignored by Git. It contains `deployment_target = "aws"`,
`aws_region`, and `aws_account_id`; it must not contain credentials. Resource
names include the account ID, and the S3 bucket receives a generated unique
suffix. The AWS provider and Makefile both check that the authenticated account
matches the configured ID.

Authenticate with the profile you want Terraform to use. For an IAM Identity
Center profile:

```bash
aws sso login --profile aws-primer
AWS_PROFILE=aws-primer aws sts get-caller-identity
```

Confirm the returned account ID before proceeding. AWS CLI `aws login` is also
available for interactive console sign-in and requires AWS CLI 2.32.0 or later;
see [AWS CLI sign-in options](https://docs.aws.amazon.com/signin/latest/userguide/command-line-sign-in.html).

The profile needs permission to create the resources in the Terraform plan,
including IAM roles and policies, and to pass the Lambda execution role to
Lambda. Restrict `iam:PassRole` to this spike's role. See [Grant a user
permissions to pass a role to an AWS service](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_passrole.html).
The Lambda execution role itself can read SQS messages, write to the generated
S3 bucket's `processed/` prefix, write DynamoDB items, and write CloudWatch
Logs. AWS documents the queue permissions and timeout requirements in the
[SQS event source mapping guide](https://docs.aws.amazon.com/lambda/latest/dg/services-sqs-configure.html).

## Plan, deploy, and verify

Run the AWS plan first. It does not apply resources:

```bash
make SPIKE=spike-1 aws-plan AWS_PROFILE=aws-primer
```

Review the target account, Region, generated bucket prefix, and resource list.
Then deploy:

```bash
make SPIKE=spike-1 aws-apply AWS_PROFILE=aws-primer
```

Terraform asks for confirmation before applying. To run the end-to-end check,
which sends one SQS message and verifies the matching S3 object and DynamoDB
item:

```bash
make SPIKE=spike-1 aws-e2e AWS_PROFILE=aws-primer
```

AWS E2E leaves the deployed resources running so you can inspect them. AWS
usage can incur charges while they exist. The AWS stack uses a separate local
Terraform state file (`terraform.aws.tfstate`), while Floci keeps using
`terraform.tfstate`. Keep these state files with their respective deployments.

The local `plan`, `apply`, `e2e`, and `destroy` targets remain Floci-only; they
use test credentials and localhost endpoints. AWS targets do not start Floci.

## Clean up

The AWS bucket has `force_destroy = false`. `aws-destroy` checks that it is
empty and refuses to proceed while objects remain. Empty the demo objects, then
destroy the stack:

```bash
make SPIKE=spike-1 aws-terraform-init
REGION=us-east-1 # use aws_region from aws.tfvars
S3_BUCKET=$(AWS_PROFILE=aws-primer terraform -chdir=src/spike-1 \
  output -raw uploads_bucket_name)
AWS_PROFILE=aws-primer aws s3 rm "s3://$S3_BUCKET" --recursive --region "$REGION"
make SPIKE=spike-1 aws-destroy AWS_PROFILE=aws-primer
```

`aws-destroy` also checks the profile account against `aws_account_id` before
asking Terraform to destroy the AWS resources.

## Spike 2

Spike 2 also has AWS targets for its EventBridge, Lambda, Step Functions,
DynamoDB, IAM, and SQS workflow. It uses the same profile and account checks,
with its own `aws.tfvars` and AWS state file. See the [spike 2 guide](../src/spike-2/README.md)
for its plan, E2E, and cleanup commands.
