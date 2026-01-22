# AWS Resource Tag Automation Solution

## Overview

Partner Revenue Measurement tracks AWS service consumption driven by partner products through resource tags.

This repository contains scripts in the form of AWS CloudFormation templates for automated AWS resource tagging and tag remediation, to assist you remain in compliance with the AWS Partner Revenue Measurement (PRM) program governance requirements.

You can use the scripts in this repository to build your own automation for your specific situation. Please make sure to test these in a sandbox environment and follow your organisation’s SDLC practices for production deployment.

These scripts meant to ease the adoption of Partner Revenue Measurement (PRM) providing you with ideas of how they can operationalize the implementation of PRM tagging requirements.

Under the Shared Responsibility Model, partners and customers using this project need to enhance the templates to adapt it to their own environments by (including but not limited to):
- Securing IAM permissions and implement least privilege
- Enabling encryption (AWS Key Management Service (AWS KMS)) for AWS CloudTrail logs
- Implementing Amazon S3 Object Lock for log immutability
- Monitoring and responding to security events
- Facilitating compliance with organizational policies
- Implementing any other security and operational change that apply to their own industry

## Solution Components

1. **Auto-Tagging** (`deployment/auto-tagging.yaml`): Automatically tags newly created AWS resources (Amazon Elastic Compute Cloud (Amazon EC2), Amazon Relational Database Service (Amazon RDS), Amazon Simple Storage Service (Amazon S3), AWS Lambda)
2. **Tag Monitoring & Remediation** (`remediation/ec2-tag-monitor.yaml`): Monitors and automatically restores critical tags if modified or removed

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

