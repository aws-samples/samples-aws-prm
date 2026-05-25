# Tag Remediation Automation

## Important Notices

> **Sample code — not production-ready.** This template requires security hardening, cost review, and adaptation before use in any real environment.

- **Security review required.** IAM policies use `Resource: '*'`. You must scope permissions to specific resource ARNs, enable KMS encryption for CloudTrail, and consider VPC isolation for the Lambda function. Automatic remediation can override legitimate changes — implement an authorization mechanism or emergency override.
- **Cost implications.** This stack creates a CloudTrail trail (multi-region), an S3 bucket for log storage, a Lambda function, and an EventBridge rule. Estimated monthly cost: $1–$13 depending on tag change frequency and log retention.
- **Adapt for your environment.** The monitored resource ARNs, tag key, and tag value must be configured for your specific resources and PRM product code.

## What It Does

Monitors specified AWS resources and automatically restores the `aws-apn-id` tag if it is modified or removed:

1. **EventBridge** listens for `Tag Change on Resource` events filtered to specific resource ARNs and the monitored tag key.
2. **Lambda function** receives the event and re-applies the original tag value using the Resource Groups Tagging API.

This ensures PRM compliance tags remain intact even if accidentally or intentionally removed.

## Architecture

```
Tag Change Event → EventBridge Rule (filtered by ARN + tag key) → Lambda → Resource Groups Tagging API
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `OriginalTagKey` | `aws-apn-id` | Tag key to monitor and restore |
| `OriginalTagValue` | `pc:137a4305-1a46-436b-bc3b-d40cf4a27637` | Tag value to restore (replace with your PRM product code) |
| `ResourceArns` | *(placeholder)* | Comma-separated list of resource ARNs to monitor |

## Deployment

### Deploy the stack

```bash
aws cloudformation deploy \
  --template-file remediation/ec2-tag-monitor.yaml \
  --stack-name prm-tag-remediation \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    OriginalTagKey=aws-apn-id \
    OriginalTagValue="pc:YOUR-PRODUCT-CODE-HERE" \
    ResourceArns="arn:aws:ec2:REGION:ACCOUNT:instance/i-xxx,arn:aws:ec2:REGION:ACCOUNT:instance/i-yyy" \
  --region YOUR-REGION
```

### Verify it works

1. Remove the monitored tag from one of the specified resources:
   ```bash
   aws ec2 delete-tags --resources i-xxx --tags Key=aws-apn-id --region YOUR-REGION
   ```
2. Wait a few seconds for the EventBridge event to trigger the Lambda.
3. Check the tags are restored:
   ```bash
   aws ec2 describe-tags --filters "Name=resource-id,Values=i-xxx" --region YOUR-REGION
   ```

### Update monitored resources

To add or remove resources from monitoring, redeploy with an updated `ResourceArns` parameter:

```bash
aws cloudformation deploy \
  --template-file remediation/ec2-tag-monitor.yaml \
  --stack-name prm-tag-remediation \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    OriginalTagKey=aws-apn-id \
    OriginalTagValue="pc:YOUR-PRODUCT-CODE-HERE" \
    ResourceArns="arn:aws:ec2:REGION:ACCOUNT:instance/i-xxx,arn:aws:ec2:REGION:ACCOUNT:instance/i-zzz" \
  --region YOUR-REGION
```

### Delete the stack

Empty the CloudTrail S3 bucket first (versioned objects must be deleted), then:

```bash
aws s3 rm s3://prm-tag-remediation-cloudtrail-ACCOUNT-ID --recursive
# Delete all object versions if versioning is enabled
aws cloudformation delete-stack --stack-name prm-tag-remediation --region YOUR-REGION
```

## Resources Created

| Resource | Type | Purpose |
|---|---|---|
| `TagRemediationFunction` | Lambda Function | Restores tags on monitored resources |
| `LambdaExecutionRole` | IAM Role | Execution role for the Lambda |
| `ResourceTagChangeRule` | EventBridge Rule | Triggers on tag changes for monitored ARNs |
| `CloudTrail` | CloudTrail Trail | Captures API calls |
| `CloudTrailBucket` | S3 Bucket | Stores CloudTrail logs |

## Limitations

- **Static resource list.** Monitored ARNs are passed as a CloudFormation parameter — you must redeploy to add or remove resources. Consider using DynamoDB or tag-based discovery for dynamic environments.
- **No emergency override.** The Lambda will restore tags even during incident response. Implement a kill switch (e.g., DynamoDB exemptions table or SSM Parameter Store flag) for production use.
- **CloudTrail delay.** Tag change events typically arrive within seconds via EventBridge, but there may be occasional delays.

## License

MIT-0 — see [LICENSE](../LICENSE).
