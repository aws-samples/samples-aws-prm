# Tag Remediation Automation

This folder contains the **dynamic tag compliance** system
(`dynamic-tag-compliance.yaml`), an event-driven stack that automatically restores
required tags on AWS resources. A DynamoDB registry is the source of truth for which
resources require which tags, so you add or remove monitored resources at runtime
without redeploying the stack.

> An older static template, `ec2-tag-monitor.yaml`, hardcodes resource ARNs and a single
> tag as CloudFormation parameters. It is kept for reference only — prefer the dynamic
> stack documented below.

## Important Notices

> **Sample code — not production-ready.** This template requires security hardening, cost review, and adaptation before use in any real environment.

- **Security review required.** The Lambda execution role attaches the AWS-managed `ResourceGroupsTaggingAPITagUntagSupportedResources` policy, which grants tag/untag permissions across nearly all services on `Resource: '*'`. This broad access is inherent to service-agnostic remediation — scope it down (e.g., with an `aws:TagKeys` condition) before production use. Automatic remediation can also override legitimate changes; implement an authorization mechanism or emergency override.
- **Cost implications.** This stack creates a CloudTrail trail (multi-region), an S3 bucket for log storage, a DynamoDB table (on-demand), a Lambda function, an SQS dead-letter queue, and an EventBridge rule. Estimated monthly cost: $1–$13 depending on tag change frequency and log retention. Note that a multi-region trail duplicates management-event logging if the account already has one.
- **Adapt for your environment.** Populate the DynamoDB compliance registry with the resource ARNs and required tags specific to your environment and PRM product code.

## Best Practices

### Protect stateful resources with retention policies

For production deployments, stateful resources that hold data you cannot easily recreate — such as the DynamoDB compliance registry, the CloudTrail log bucket, and the SQS dead-letter queue — should set explicit `DeletionPolicy: Retain` and `UpdateReplacePolicy: Retain`. This prevents accidental data loss if the stack is deleted or if an update forces resource replacement.

```yaml
ComplianceRegistryTable:
  Type: AWS::DynamoDB::Table
  DeletionPolicy: Retain
  UpdateReplacePolicy: Retain
  Properties:
    # ...
```

These policies are intentionally omitted from the sample templates in this repo so that `delete-stack` cleans up all resources during testing and demos. Add them before deploying to any environment where the data matters. Note the tradeoff: with `Retain`, a retained resource keeps its name after stack deletion, which can cause a naming collision if you later redeploy the same stack.

## What It Does

Monitors AWS resources registered in a DynamoDB table and automatically restores their required tags if those tags are modified or removed:

1. **CloudTrail** captures tagging API calls, which AWS turns into `Tag Change on Resource` events.
2. **EventBridge** matches all `Tag Change on Resource` events (`source: aws.tag`) — without filtering by ARN — and invokes the Lambda.
3. **Lambda function** checks for self-invocation, looks up the resource ARN in the **DynamoDB compliance registry**, compares current tags against the required tags, and reapplies the required tags via the Resource Groups Tagging API when they differ.
4. Events that fail after retries are sent to an **SQS dead-letter queue** for investigation.

Because the "is this resource monitored?" decision happens at runtime against DynamoDB, you manage compliance rules by editing table items — no stack redeploy required.

## Architecture

```
Tag Change → CloudTrail → EventBridge Rule (source: aws.tag) → Lambda
                                                                 ├─ self-invocation check
                                                                 ├─ DynamoDB GetItem (by ARN)
                                                                 ├─ compare current vs required tags
                                                                 ├─ Resource Groups Tagging API (tag_resources)
                                                                 └─ SQS dead-letter queue (on failure)
```

## Parameters

The dynamic stack requires **no parameters**. Resource names are derived from the stack
name, and monitored resources are defined as items in the DynamoDB registry rather than
as template parameters.

## Deployment

### Deploy the stack

```bash
aws cloudformation deploy \
  --template-file remediation/dynamic-tag-compliance.yaml \
  --stack-name dynamic-tag-compliance \
  --capabilities CAPABILITY_NAMED_IAM \
  --region YOUR-REGION
```

`CAPABILITY_NAMED_IAM` is required because the stack creates a named IAM role.

### Register a resource for monitoring

Add an item to the compliance registry table. The partition key is `resource_arn`, and
`required_tags` is a map of the tag key-value pairs the resource must maintain:

```bash
aws dynamodb put-item \
  --table-name dynamic-tag-compliance-ComplianceRegistry \
  --region YOUR-REGION \
  --item '{
    "resource_arn": {"S": "arn:aws:ec2:REGION:ACCOUNT:instance/i-xxx"},
    "required_tags": {"M": {"aws-apn-id": {"S": "pc:YOUR-PRODUCT-CODE-HERE"}}}
  }'
```

To stop monitoring a resource, delete its item:

```bash
aws dynamodb delete-item \
  --table-name dynamic-tag-compliance-ComplianceRegistry \
  --region YOUR-REGION \
  --key '{"resource_arn": {"S": "arn:aws:ec2:REGION:ACCOUNT:instance/i-xxx"}}'
```

### Verify it works

1. Remove a required tag from a registered resource:
   ```bash
   aws ec2 delete-tags --resources i-xxx --tags Key=aws-apn-id --region YOUR-REGION
   ```
2. Wait up to ~60 seconds for the event to flow through EventBridge to the Lambda.
3. Confirm the tag was restored:
   ```bash
   aws ec2 describe-tags --filters "Name=resource-id,Values=i-xxx" --region YOUR-REGION
   ```
4. Inspect the structured Lambda logs to see the outcome (`received`, `remediated`, `skipped`, or `failed`):
   ```bash
   aws logs tail /aws/lambda/dynamic-tag-compliance-RemediationLambda --since 10m --region YOUR-REGION
   ```

### Delete the stack

The CloudTrail S3 bucket is versioned, so its object versions and delete markers must be
removed before `delete-stack` can delete the bucket:

```bash
# Remove current objects
aws s3 rm s3://dynamic-tag-compliance-cloudtrail-logs-ACCOUNT-ID --recursive --region YOUR-REGION
# Also delete all noncurrent versions and delete markers (versioned bucket),
# then delete the stack:
aws cloudformation delete-stack --stack-name dynamic-tag-compliance --region YOUR-REGION
```

## Resources Created

| Resource | Type | Purpose |
|---|---|---|
| `ComplianceRegistryTable` | DynamoDB Table | Registry mapping resource ARNs to their required tags |
| `RemediationLambdaFunction` | Lambda Function | Looks up compliance rules and reapplies required tags |
| `RemediationLambdaRole` | IAM Role | Execution role (DynamoDB read, SQS send, broad tagging via AWS-managed policy) |
| `TagChangeEventRule` | EventBridge Rule | Triggers the Lambda on all `Tag Change on Resource` events |
| `LambdaInvokePermission` | Lambda Permission | Allows EventBridge to invoke the Lambda |
| `DeadLetterQueue` | SQS Queue | Captures events that fail after retries |
| `DeadLetterQueuePolicy` | SQS Queue Policy | Allows EventBridge to send to the DLQ |
| `CloudTrail` | CloudTrail Trail | Captures tagging API calls (multi-region) |
| `CloudTrailBucket` | S3 Bucket | Stores CloudTrail logs (versioned, encrypted, TLS-only) |
| `CloudTrailBucketPolicy` | S3 Bucket Policy | Grants CloudTrail write access; denies insecure transport |

## Requirements for the Automation to Work

This stack is event-driven: it reacts to the AWS-generated `Tag Change on Resource` event
(`source: aws.tag`) delivered through EventBridge. For a resource to be monitored and
remediated, **all** of the following must hold:

1. **The service must emit `Tag Change on Resource` events.** These events are
   produced by AWS's centralized tagging system, which forwards them to EventBridge.
   Not every taggable service is integrated with this system — if a service does not
   emit the event, the Lambda is never invoked and no remediation occurs.
2. **The service must be supported by the Resource Groups Tagging API.** The Lambda
   applies tags through a single `tag_resources` call, which depends on the underlying
   per-service tagging permissions granted by the
   `ResourceGroupsTaggingAPITagUntagSupportedResources` AWS-managed policy. See
   [Services that support the Resource Groups Tagging API](https://docs.aws.amazon.com/resourcegroupstagging/latest/APIReference/supported-services.html).
3. **CloudTrail must be capturing management events** in the account/region, since
   `Tag Change on Resource` events are derived from the tagging API calls CloudTrail records.

## Limitations

- **Service coverage is not universal.** Some taggable services do **not** emit
  `Tag Change on Resource` events and therefore cannot be remediated by this automation,
  even though they appear in the compliance registry and support the Resource Groups
  Tagging API. **Amazon Kinesis Data Streams is a confirmed example:** removing a tag
  from a stream produces no EventBridge event, so the Lambda is never triggered and the
  tag is not restored. Verified-working services include EC2 instances, S3 buckets,
  DynamoDB tables, Lambda functions, and RDS instances. Before relying on this automation
  for a given service, confirm it emits `Tag Change on Resource` events (e.g., make a tag
  change and check for the event in EventBridge/CloudWatch Logs). For services that do not
  emit the event, use an alternative such as a CloudTrail-pattern EventBridge rule matching
  that service's specific tag API calls, or a periodic compliance scan as a backstop.
- **No emergency override.** The Lambda will restore tags even during incident response. Implement a kill switch (e.g., a DynamoDB exemptions flag or SSM Parameter Store flag) for production use.
- **Broad tagging permissions.** The execution role can tag/untag nearly all resources in the account. Scope this down with an `aws:TagKeys` condition or a narrower policy for production.
- **CloudTrail delay.** Tag change events typically arrive within seconds via EventBridge, but there may be occasional delays.

## License

MIT-0 — see [LICENSE](../LICENSE).
