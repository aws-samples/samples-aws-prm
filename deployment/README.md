# Auto-Tagging Automation

## Important Notices

> **Sample code — not production-ready.** This template requires security hardening, cost review, and adaptation before use in any real environment.

- **Security review required.** IAM policies use `Resource: '*'`. You must scope permissions to specific resource ARNs, enable KMS encryption for CloudTrail, and consider VPC isolation for the Lambda function.
- **Cost implications.** This stack creates a CloudTrail trail (multi-region), an S3 bucket for log storage, a Lambda function, and EventBridge rules. Estimated monthly cost: $1–$13 depending on API call volume and log retention.
- **Adapt for your environment.** Tag keys, values, and monitored event types should be customized to match your PRM configuration and organizational tagging strategy.

## What It Does

Automatically applies the `aws-apn-id` tag to newly created AWS resources by:

1. **CloudTrail** captures management API calls across all regions.
2. **EventBridge rules** filter for resource creation events (`RunInstances`, `CreateDBInstance`, `CreateDBCluster`, `CreateBucket`, `CreateFunction`).
3. **Lambda function** extracts resource ARNs from the event and applies the configured tag using the Resource Groups Tagging API.

## Architecture

```
CloudTrail → EventBridge Rule → Lambda → Resource Groups Tagging API
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `AutoTagKey` | `aws-apn-id` | Tag key to apply |
| `AutoTagValue` | `11111` | Tag value to apply (replace with your PRM product code) |

## Deployment

### Deploy the stack

```bash
aws cloudformation deploy \
  --template-file deployment/auto-tagging.yaml \
  --stack-name prm-auto-tagging \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    AutoTagKey=aws-apn-id \
    AutoTagValue="pc:YOUR-PRODUCT-CODE-HERE" \
  --region YOUR-REGION
```

### Verify it works

1. Launch a test EC2 instance in the same region.
2. Wait 5–15 minutes for the CloudTrail event to propagate.
3. Check the instance tags:
   ```bash
   aws ec2 describe-tags --filters "Name=resource-id,Values=YOUR-INSTANCE-ID"
   ```

### Update the stack

```bash
aws cloudformation deploy \
  --template-file deployment/auto-tagging.yaml \
  --stack-name prm-auto-tagging \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    AutoTagKey=aws-apn-id \
    AutoTagValue="pc:NEW-PRODUCT-CODE" \
  --region YOUR-REGION
```

### Delete the stack

Empty the CloudTrail S3 bucket first (versioned objects must be deleted), then:

```bash
aws s3 rm s3://prm-auto-tagging-autotag-trail-ACCOUNT-ID --recursive
# Delete all object versions if versioning is enabled
aws cloudformation delete-stack --stack-name prm-auto-tagging --region YOUR-REGION
```

## Resources Created

| Resource | Type | Purpose |
|---|---|---|
| `AutoTagFunction` | Lambda Function | Applies tags to new resources |
| `AutoTagLambdaRole` | IAM Role | Execution role for the Lambda |
| `EC2CreationRule` | EventBridge Rule | Triggers on EC2 instance launches |
| `RDSCreationRule` | EventBridge Rule | Triggers on RDS instance/cluster creation |
| `S3CreationRule` | EventBridge Rule | Triggers on S3 bucket creation |
| `LambdaCreationRule` | EventBridge Rule | Triggers on Lambda function creation |
| `AutoTagCloudTrail` | CloudTrail Trail | Captures API calls |
| `AutoTagCloudTrailBucket` | S3 Bucket | Stores CloudTrail logs |

## Limitations

- CloudTrail events have a 5–15 minute delay — tagging is eventually consistent, not real-time.
- Only covers EC2, RDS, S3, and Lambda creation events. Add more EventBridge rules for other services.
- No dead-letter queue configured — failed Lambda invocations are retried but not persisted.

## License

MIT-0 — see [LICENSE](../LICENSE).
