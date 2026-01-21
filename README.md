# AWS Resource Tag Automation Solution

## Overview

This repository contains AWS CloudFormation templates for automated AWS resource tagging and tag remediation, designed for compliance with the Partner Revenue Measurement (PRM) program and other governance requirements. 

This is a sample project that customers can use a first step to build their own automation. The templates in this project are not meant to be deploy in production environments, but rather to ease the adoption of Partner Revenue Measurement (PRM) providing partners/customers with sample ideas of how they can operationalize the implementation of PRM tagging. 

Under the Shared Resposability Model, partners and customer using this project need to enhance the templates to adapt it to their onw environments by (if applicable):

- Securing IAM permissions and implement least privilege
- Enabling encryption (AWS Key Management Service (AWS KMS)) for AWS CloudTrail logs
- Implementing Amazon S3 Object Lock for log immutability
- Monitoring and respond to security events
- Facilitating compliance with organizational policies
- Implementing any other security and operational change that apply to their own industry

## Solution Components

1. **Auto-Tagging** (`deployment/auto-tagging.yaml`): Automatically tags newly created AWS resources (Amazon Elastic Compute Cloud (Amazon EC2), Amazon Relational Database Service (Amazon RDS), Amazon Simple Storage Service (Amazon S3), AWS Lambda)
2. **Tag Monitoring & Remediation** (`remediation/ec2-tag-monitor.yaml`): Monitors and automatically restores critical tags if modified or removed


## Risk Assessment

**IMPORTANT:** Before deploying this solution, please review the comprehensive [Risk Assessment](RISK_ASSESSMENT.md) document, which covers:

- Security risks (IAM permissions, tag conflicts, Lambda security)
- Operational risks (automatic remediation overrides, Lambda failures)
- Cost implications (CloudTrail storage, Lambda invocations)
- Compliance considerations (audit trails, data retention, privacy)


## Getting Started

### Prerequisites

- AWS Account with appropriate permissions
- AWS CLI configured
- AWS CloudFormation deployment permissions

### Deployment

1. **Deploy Auto-Tagging Solution**:
   ```bash
   aws cloudformation create-stack \
     --stack-name prm-auto-tagging \
     --template-body file://deployment/auto-tagging.yaml \
     --parameters ParameterKey=AutoTagKey,ParameterValue=aws-apn-id \
                  ParameterKey=AutoTagValue,ParameterValue=pc:YOUR-ID-HERE \
     --capabilities CAPABILITY_IAM
   ```

2. **Deploy Tag Monitoring & Remediation**:
   ```bash
   aws cloudformation create-stack \
     --stack-name prm-tag-monitor \
     --template-body file://remediation/ec2-tag-monitor.yaml \
     --parameters ParameterKey=OriginalTagKey,ParameterValue=aws-apn-id \
                  ParameterKey=OriginalTagValue,ParameterValue=pc:YOUR-ID-HERE \
                  ParameterKey=ResourceArns,ParameterValue="arn:aws:ec2:region:account:instance/i-xxx" \
     --capabilities CAPABILITY_IAM
   ```

### Architecture Diagrams

Visual representations of the solution architecture:

**Auto-Tagging Solution:**

![Auto-Tagging Architecture](generated-diagrams/auto-tagging-solution.png)

**Tag Monitoring & Remediation Solution:**

![Tag Monitoring Architecture](generated-diagrams/tag-monitoring-solution.png)

### Auto-Tagging Flow
1. Resource created (Amazon EC2, Amazon RDS, Amazon S3, AWS Lambda)
2. AWS CloudTrail logs API call (5-15 min delay)
3. Amazon EventBridge detects creation event
4. AWS Lambda function applies configured tags
5. Resource is tagged with aws-apn-id

### Tag Remediation Flow
1. Tag modified or removed on monitored resource
2. AWS CloudTrail logs tag change (5-15 min delay)
3. Amazon EventBridge detects tag change event
4. AWS Lambda function validates resource is monitored
5. AWS Lambda restores original tag value
6. Action logged to Amazon CloudWatch for audit

## Security Considerations

This solution requires careful security configuration:

- AWS Lambda functions need broad tagging permissions
- AWS CloudTrail logs may contain sensitive API call information
- Automatic remediation may override legitimate changes
- Emergency override mechanism required for incident response

See [RISK_ASSESSMENT.md](RISK_ASSESSMENT.md) for complete security analysis and mitigation strategies.

## License

Copyright (c) 2026 AWS  
Licensed under the MIT License
