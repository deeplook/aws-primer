# AWS Primer experiments

This repository is an early Terraform-first AWS primer. The spikes are
self-contained under `src/`; each has its own Terraform configuration, Compose
file, Makefile, README, and end-to-end check. Both spikes support local Floci
and explicit AWS targets.

```bash
make list
make help
make SPIKE=spike-1 e2e
make SPIKE=spike-2 e2e
```

## Pre-commit checks

Install the `pre-commit` tool, then enable the repository hook once per
checkout:

```bash
pre-commit install
```

The config runs `check-all` for both spikes, including Terraform formatting
and validation, Python syntax, and Bash syntax checks. These checks also run in
CI.

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

AWS E2E leaves resources running for inspection. Each spike uses separate
local and AWS Terraform state files. See [Deploying spike 1 to AWS](docs/deploy-to-aws.md)
and the [spike 2 guide](src/spike-2/README.md) for setup, verification,
and cleanup instructions.
