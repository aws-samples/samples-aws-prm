# Historical Backfill Automation

## Important Notices

> **Sample code — not production-ready.** This container and its configuration require security hardening, cost review, and adaptation before use in any real environment.

- **Security review required.** The Fargate task role needs access to CloudTrail S3 logs and the Resource Groups Tagging API. Scope IAM permissions to specific buckets and resource ARNs. Ensure the container runs in a private subnet with appropriate security groups.
- **Cost implications.** Running the Fargate task incurs compute charges (~$0.02/hour for 0.5 vCPU / 1 GB) plus S3 GET request costs. A typical backfill of one year of logs completes in 15–60 minutes, costing under $0.05. Monitor task duration for large accounts.
- **Adapt for your environment.** Role mappings, trail bucket names, and network configuration must be customized for your AWS account and partner setup.

## What It Does

Retroactively applies `aws-apn-id` tags to resources created by partner IAM roles by scanning historical CloudTrail logs stored in S3:

1. Lists all `.json.gz` CloudTrail log files under the configured S3 prefix.
2. Downloads and decompresses each log file.
3. Filters for resource-creation events (`Create*`, `Run*`, `Allocate*`, `Register*`, `Import*`, `Provision*`, `Put*`, `Launch*`).
4. Checks if the caller matches a configured partner IAM role.
5. Extracts resource ARNs from the CloudTrail response (explicit extractors for EC2, SQS, Redshift, Route 53; generic ARN scanner for other services).
6. Applies `aws-apn-id: pc:<product-code>` via the Resource Groups Tagging API.

This is useful for tagging resources created before the real-time auto-tagging automation was deployed, or for processing logs beyond the 90-day CloudTrail `LookupEvents` API limit.

## Architecture

```
Fargate Task → S3 (CloudTrail logs) → Parse events → Resource Groups Tagging API
```

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `ROLE_MAPPINGS` | Yes | — | Role-to-product-code mappings. Format: `role1=pc1,role2=pc2` |
| `TRAIL_BUCKET` | Yes | — | S3 bucket containing CloudTrail logs |
| `TRAIL_PREFIX` | No | `AWSLogs/` | S3 key prefix for CloudTrail logs |
| `AWS_ACCOUNT_ID` | No | Auto-detected via STS | Account ID to scope the S3 prefix |
| `LOG_LEVEL` | No | `INFO` | `DEBUG`, `INFO`, `WARNING`, or `ERROR` |

## Deployment

### Prerequisites

- Docker installed locally
- An ECR repository to push the container image
- A CloudTrail trail delivering logs to an S3 bucket
- A Fargate cluster with appropriate IAM roles and networking

### Build and push the container image

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
REPO_NAME="prm-backfill"

# Create ECR repository (if it doesn't exist)
aws ecr create-repository --repository-name "$REPO_NAME" --region "$REGION" 2>/dev/null

# Authenticate Docker to ECR
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Build and push
docker build -t "${REPO_NAME}:latest" .
docker tag "${REPO_NAME}:latest" "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:latest"
docker push "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:latest"
```

### Run the backfill task

```bash
aws ecs run-task \
  --cluster YOUR-CLUSTER \
  --task-definition YOUR-TASK-DEFINITION \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx],assignPublicIp=ENABLED}" \
  --overrides '{
    "containerOverrides": [{
      "name": "backfill",
      "environment": [
        {"name": "ROLE_MAPPINGS", "value": "partner-role-name=your-product-code"},
        {"name": "TRAIL_BUCKET", "value": "your-cloudtrail-bucket"},
        {"name": "LOG_LEVEL", "value": "INFO"}
      ]
    }]
  }'
```

The task needs outbound internet access (or VPC endpoints for S3, STS, and Resource Groups Tagging API).

## Monitoring

Logs are sent to CloudWatch Logs. Progress is logged every 100 files:

```
Scanning s3://my-trail-bucket/AWSLogs/123456789012/CloudTrail/
Progress: 100 files processed, 12 resources tagged
Progress: 200 files processed, 27 resources tagged
Done. 243 files processed, 31 resources tagged.
```

## Cleanup

The Fargate task stops automatically after processing all log files. To clean up:

1. Delete the ECR repository and image.
2. Remove the ECS cluster and task definition (if created manually).
3. Delete any associated IAM roles.

## Limitations

- **No incremental processing.** The script scans all log files on every run. For large accounts, consider adding date-range filtering or a checkpoint mechanism.
- **Resource must still exist.** Tagging will fail for resources that have been terminated or deleted since the CloudTrail event was recorded.
- **Rate limits.** The Resource Groups Tagging API has rate limits. The script batches requests (20 ARNs per call) but does not implement backoff.

## License

MIT-0 — see [LICENSE](../LICENSE).
