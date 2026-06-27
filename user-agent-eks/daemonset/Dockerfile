# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Minimal DaemonSet image: AWS CLI v2 plus the calendar-aligned touch loop.
FROM public.ecr.aws/aws-cli/aws-cli:latest

COPY touch-loop.sh /usr/local/bin/touch-loop.sh
RUN chmod +x /usr/local/bin/touch-loop.sh

ENTRYPOINT ["/usr/local/bin/touch-loop.sh"]
