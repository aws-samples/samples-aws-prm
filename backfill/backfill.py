"""
S3 CloudTrail backfill for APN PRM Auto-Tagger.

Scans CloudTrail log files stored in S3, finds resource creation events
from partner IAM roles, and applies the aws-apn-id tag.

Runs as a Fargate container — no timeout constraints.

Environment variables (set via SAM template / ECS task definition):
  ROLE_MAPPINGS       — same format as the Lambda: role1=pc1,role2=pc2
  TRAIL_BUCKET        — S3 bucket containing CloudTrail logs
  TRAIL_PREFIX        — S3 key prefix for logs (default: AWSLogs/)
  AWS_ACCOUNT_ID      — account ID to scope the S3 prefix
  LOG_LEVEL           — DEBUG, INFO, WARNING, ERROR (default: INFO)
"""

import gzip
import json
import logging
import os
import boto3

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)

s3_client = boto3.client("s3")
tagging_client = boto3.client("resourcegroupstaggingapi")

TRAIL_BUCKET = os.environ["TRAIL_BUCKET"]
TRAIL_PREFIX = os.environ.get("TRAIL_PREFIX", "AWSLogs/")
AWS_ACCOUNT_ID = os.environ.get("AWS_ACCOUNT_ID", boto3.client("sts").get_caller_identity()["Account"])

CREATION_PREFIXES = (
    "Create", "Run", "Allocate", "Register",
    "Import", "Provision", "Put", "Launch",
)

# Parse ROLE_MAPPINGS
ROLE_PRODUCT_MAP = {}
for entry in os.environ.get("ROLE_MAPPINGS", "").split(","):
    entry = entry.strip()
    if "=" in entry:
        role_id, pc = entry.split("=", 1)
        ROLE_PRODUCT_MAP[role_id.strip()] = pc.strip()


def match_partner_role(user_identity):
    arn = user_identity.get("arn", "")
    session_issuer = user_identity.get("sessionContext", {}).get("sessionIssuer", {})
    role_arn = session_issuer.get("arn", "")
    role_name = session_issuer.get("userName", "")
    candidates = [arn, role_arn, role_name]
    for role_id, product_code in ROLE_PRODUCT_MAP.items():
        if any(role_id in c for c in candidates):
            return product_code
    return None


def apply_tags(arns, product_code):
    tag_value = f"pc:{product_code}"
    tagged = []
    for i in range(0, len(arns), 20):
        batch = arns[i:i + 20]
        try:
            response = tagging_client.tag_resources(
                ResourceARNList=batch,
                Tags={"aws-apn-id": tag_value},
            )
            failed = response.get("FailedResourcesMap", {})
            for arn in batch:
                if arn not in failed:
                    tagged.append(arn)
                else:
                    logger.warning("Failed to tag %s: %s", arn, failed[arn])
        except Exception:
            logger.exception("Error tagging batch")
    return tagged


def _account_and_region(record):
    account = record.get("recipientAccountId", record.get("userIdentity", {}).get("accountId", ""))
    region = record.get("awsRegion", "")
    return account, region


# Explicit ARN extractors for services that return IDs/URLs instead of ARNs.
# Keyed by (eventSource, eventName). eventSource here uses the CloudTrail format
# e.g. "ec2.amazonaws.com", not the EventBridge format "aws.ec2".
ARN_EXTRACTORS = {}


def extractor(*keys):
    """Decorator to register an ARN extractor for (eventSource, eventName) tuples."""
    def decorator(func):
        for key in keys:
            ARN_EXTRACTORS[key] = func
        return func
    return decorator


@extractor(("ec2.amazonaws.com", "RunInstances"))
def _ec2_run_instances(record):
    items = record.get("responseElements", {}).get("instancesSet", {}).get("items", [])
    account, region = _account_and_region(record)
    return [f"arn:aws:ec2:{region}:{account}:instance/{i['instanceId']}" for i in items if "instanceId" in i]


@extractor(("ec2.amazonaws.com", "CreateVpc"))
def _ec2_create_vpc(record):
    vpc_id = record.get("responseElements", {}).get("vpc", {}).get("vpcId")
    account, region = _account_and_region(record)
    return [f"arn:aws:ec2:{region}:{account}:vpc/{vpc_id}"] if vpc_id else []


@extractor(("ec2.amazonaws.com", "CreateSubnet"))
def _ec2_create_subnet(record):
    sid = record.get("responseElements", {}).get("subnet", {}).get("subnetId")
    account, region = _account_and_region(record)
    return [f"arn:aws:ec2:{region}:{account}:subnet/{sid}"] if sid else []


@extractor(("ec2.amazonaws.com", "CreateSecurityGroup"))
def _ec2_create_sg(record):
    sg_id = record.get("responseElements", {}).get("groupId")
    account, region = _account_and_region(record)
    return [f"arn:aws:ec2:{region}:{account}:security-group/{sg_id}"] if sg_id else []


@extractor(("ec2.amazonaws.com", "AllocateAddress"))
def _ec2_allocate_address(record):
    alloc_id = record.get("responseElements", {}).get("allocationId")
    account, region = _account_and_region(record)
    return [f"arn:aws:ec2:{region}:{account}:elastic-ip/{alloc_id}"] if alloc_id else []


@extractor(("ec2.amazonaws.com", "CreateVolume"))
def _ec2_create_volume(record):
    vol_id = record.get("responseElements", {}).get("volumeId")
    account, region = _account_and_region(record)
    return [f"arn:aws:ec2:{region}:{account}:volume/{vol_id}"] if vol_id else []


@extractor(("sqs.amazonaws.com", "CreateQueue"))
def _sqs_create_queue(record):
    url = record.get("responseElements", {}).get("queueUrl", "")
    if not url:
        return []
    queue_name = url.rstrip("/").split("/")[-1]
    account, region = _account_and_region(record)
    return [f"arn:aws:sqs:{region}:{account}:{queue_name}"]


@extractor(("redshift.amazonaws.com", "CreateCluster"))
def _redshift_create_cluster(record):
    cluster_id = record.get("responseElements", {}).get("clusterIdentifier")
    account, region = _account_and_region(record)
    return [f"arn:aws:redshift:{region}:{account}:cluster:{cluster_id}"] if cluster_id else []


@extractor(("route53.amazonaws.com", "CreateHostedZone"))
def _route53_create_hosted_zone(record):
    zone_id = record.get("responseElements", {}).get("hostedZone", {}).get("id", "")
    zone_id = zone_id.replace("/hostedzone/", "")
    return [f"arn:aws:route53:::hostedzone/{zone_id}"] if zone_id else []


def extract_arns(record):
    """Try explicit extractor first, fall back to generic ARN scanner."""
    event_source = record.get("eventSource", "")
    event_name = record.get("eventName", "")
    extractor_fn = ARN_EXTRACTORS.get((event_source, event_name))
    if extractor_fn:
        return extractor_fn(record)
    return scan_response_for_arns(record.get("responseElements") or {})


def scan_response_for_arns(response_elements):
    arns = []
    _find_arns(response_elements, arns)
    return arns


def _find_arns(obj, arns):
    if isinstance(obj, str):
        if obj.startswith("arn:aws:"):
            arns.append(obj)
    elif isinstance(obj, dict):
        for key, value in obj.items():
            if isinstance(value, str) and "arn" in key.lower() and value.startswith("arn:aws:"):
                arns.append(value)
            elif isinstance(value, (dict, list)):
                _find_arns(value, arns)
    elif isinstance(obj, list):
        for item in obj:
            _find_arns(item, arns)


def process_log_file(bucket, key):
    """Download, decompress, and process a single CloudTrail log file."""
    try:
        obj = s3_client.get_object(Bucket=bucket, Key=key)
        compressed = obj["Body"].read()
        data = json.loads(gzip.decompress(compressed))
    except Exception:
        logger.exception("Failed to read %s", key)
        return 0

    tagged_count = 0
    for record in data.get("Records", []):
        event_name = record.get("eventName", "")
        if not any(event_name.startswith(p) for p in CREATION_PREFIXES):
            continue

        user_identity = record.get("userIdentity", {})
        product_code = match_partner_role(user_identity)
        if not product_code:
            continue

        arns = extract_arns(record)
        if arns:
            tagged = apply_tags(arns, product_code)
            tagged_count += len(tagged)
            logger.info("Tagged %s for %s", tagged, event_name)

    return tagged_count


def list_log_files(bucket, prefix):
    """Yield all .json.gz CloudTrail log file keys under the given prefix."""
    paginator = s3_client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith(".json.gz"):
                yield key


def main():
    prefix = f"{TRAIL_PREFIX}{AWS_ACCOUNT_ID}/CloudTrail/"
    logger.info("Scanning s3://%s/%s", TRAIL_BUCKET, prefix)

    total_files = 0
    total_tagged = 0

    for key in list_log_files(TRAIL_BUCKET, prefix):
        logger.debug("Processing %s", key)
        tagged = process_log_file(TRAIL_BUCKET, key)
        total_tagged += tagged
        total_files += 1
        if total_files % 100 == 0:
            logger.info("Progress: %d files processed, %d resources tagged", total_files, total_tagged)

    logger.info("Done. %d files processed, %d resources tagged.", total_files, total_tagged)


if __name__ == "__main__":
    main()
