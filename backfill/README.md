# Backfill — S3 CloudTrail Historical Tagger

Scans CloudTrail log files stored in S3 to retroactively apply `aws-apn-id`
tags to resources created by partner IAM roles. Runs as a Fargate container
with no timeout constraints, making it suitable for processing months or years
of historical logs that exceed the 90-day CloudTrail LookupEvents API limit.

> For the real-time auto-tagger and the 90-day Lambda-based backfill, see the
> [root README](../README.md).

## How it works

1. Lists all `.json.gz` CloudTrail log files under
   `s3://<TRAIL_BUCKET>/<TRAIL_PREFIX><ACCOUNT_ID>/CloudTrail/`
2. Downloads and decompresses each log file
3. Filters for resource-creation events (`Create*`, `Run*`, `Allocate*`,
   `Register*`, `Import*`, `Provision*`, `Put*`, `Launch*`)
4. Checks if the caller matches a configured partner IAM role
5. Extracts resource ARNs from the CloudTrail response (explicit extractors
   for EC2, SQS, Redshift, and Route 53; generic ARN scanner for everything else)
6. Applies `aws-apn-id: pc:<product-code>` via the Resource Groups Tagging API

## Prerequisites

- Docker installed locally (for building the container image)
- An ECR repository to push the image to
- A CloudTrail trail delivering logs to an S3 bucket
- The SAM stack deployed with the `TrailBucketName` parameter set (this
  creates the Fargate cluster, task definition, and IAM roles)

## Build and push the container image

```bash
# Set your variables
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
STACK_NAME=apn-prm-auto-tagger
REPO_NAME="${STACK_NAME}-backfill"

# Create the ECR repository (if it doesn't exist)
aws ecr create-repository --repository-name "$REPO_NAME" --region "$REGION" 2>/dev/null

# Authenticate Docker to ECR
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Build and push
docker build -t "${REPO_NAME}:latest" backfill/
docker tag "${REPO_NAME}:latest" "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:latest"
docker push "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:latest"
```

## Run the backfill

```bash
# Get the task definition and cluster from the stack outputs
TASK_DEF=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='BackfillTaskDefinitionArn'].OutputValue" \
  --output text)

# Run the Fargate task (replace subnet and security group with your own)
aws ecs run-task \
  --cluster "${STACK_NAME}-backfill" \
  --task-definition "$TASK_DEF" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxxxx],securityGroups=[sg-xxxxx],assignPublicIp=ENABLED}"
```

The task needs outbound internet access (or VPC endpoints for S3, STS, and
Resource Groups Tagging API) to function.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `ROLE_MAPPINGS` | Yes | — | Role-to-product-code mappings. Format: `role1=pc1,role2=pc2` |
| `TRAIL_BUCKET` | Yes | — | S3 bucket containing CloudTrail logs |
| `TRAIL_PREFIX` | No | `AWSLogs/` | S3 key prefix for CloudTrail logs |
| `AWS_ACCOUNT_ID` | No | Auto-detected via STS | Account ID to scope the S3 prefix |
| `LOG_LEVEL` | No | `INFO` | `DEBUG`, `INFO`, `WARNING`, or `ERROR` |

`ROLE_MAPPINGS`, `TRAIL_BUCKET`, and `LOG_LEVEL` are automatically set by the
SAM template's task definition from the stack parameters.

## Monitoring

Logs are sent to CloudWatch Logs at `/ecs/<stack-name>-backfill`. Progress is
logged every 100 files, and a summary is printed at completion:

```
Scanning s3://my-trail-bucket/AWSLogs/123456789012/CloudTrail/
Progress: 100 files processed, 12 resources tagged
Progress: 200 files processed, 27 resources tagged
Done. 243 files processed, 31 resources tagged.
```

## Cost estimate

- Fargate (0.5 vCPU / 1 GB): ~$0.02/hour. A typical backfill of one year of
  logs completes in 15–60 minutes, costing $0.005–$0.02.
- S3 GET requests: $0.0004 per 1,000 requests.
- Total for most accounts: under $0.05.

## License

MIT-0 — see [LICENSE](../LICENSE).
