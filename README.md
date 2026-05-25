# AWS Partner Revenue Measurement (PRM) — Sample Tagging Automation

## Important Notices

> **This is a sample project.** It is provided as a starting point and requires adaptation for real-world use. Do not deploy to production without completing the steps below.

- **Security review required.** These templates use broad IAM permissions (e.g., `Resource: '*'`) and lack VPC isolation, encryption, and monitoring. A thorough security review and hardening pass is mandatory before any production deployment.
- **Cost implications.** Deploying these templates creates AWS resources (CloudTrail trails, S3 buckets, Lambda functions, EventBridge rules, and optionally Fargate tasks) that incur ongoing charges. Review the cost estimates in each automation's README and monitor your AWS bill.
- **Shared responsibility.** Under the AWS Shared Responsibility Model, you are responsible for securing, testing, and maintaining any infrastructure deployed from this project.

## Overview

This repository contains three sample automations to help AWS Partners operationalize the [AWS Partner Revenue Measurement (PRM)](https://docs.aws.amazon.com/partner-central/latest/getting-started/partner-revenue-measurement.html) tagging requirements. PRM tracks AWS service consumption driven by partner products through resource tags.

## Automations

| # | Automation | Location | Description |
|---|---|---|---|
| 1 | **Auto-Tagging** | [`deployment/`](./deployment/) | Automatically applies the `aws-apn-id` tag to newly created AWS resources (EC2, RDS, S3, Lambda) in real time using EventBridge and Lambda. |
| 2 | **Tag Remediation** | [`remediation/`](./remediation/) | Monitors critical resource tags and automatically restores them if they are modified or removed. |
| 3 | **Historical Backfill** | [`backfill/`](./backfill/) | Scans CloudTrail logs stored in S3 to retroactively tag resources created by partner IAM roles. Runs as a Fargate container with no timeout constraints. |

## Prerequisites

- An AWS account with permissions to deploy CloudFormation stacks and create IAM roles
- AWS CLI v2 installed and configured
- Docker (for the backfill container only)

## Before You Deploy

1. **Review and adapt** each template's parameters, IAM policies, and resource configurations for your environment.
2. **Restrict IAM permissions** — replace wildcard (`*`) resources with specific ARNs.
3. **Enable encryption** — configure AWS KMS for CloudTrail logs and S3 buckets.
4. **Test in a sandbox** — deploy to a non-production account first.
5. **Set up monitoring** — add CloudWatch alarms and SNS notifications for Lambda errors and untagged resources.
6. **Estimate costs** — see each automation's README for cost details.

## Repository Structure

```
.
├── deployment/          # Auto-tagging CloudFormation template
├── remediation/         # Tag remediation CloudFormation template
├── backfill/            # Historical backfill container (Dockerfile + script)
├── troubleshooting/     # Troubleshooting guides (placeholder)
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
└── LICENSE
```

## License

This project is licensed under the MIT-0 License. See [LICENSE](./LICENSE).

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.
