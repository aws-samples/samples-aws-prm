FROM public.ecr.aws/lambda/python:3.12

WORKDIR /app
COPY backfill.py .

RUN pip install boto3 --quiet

ENTRYPOINT ["python", "backfill.py"]
