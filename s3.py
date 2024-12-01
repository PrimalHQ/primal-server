import sys
import os
import json

import boto3
from botocore.exceptions import ClientError

req = json.loads(sys.stdin.buffer.readline())

s3_client = boto3.client(
    's3',
    aws_access_key_id=req['access_key'],
    aws_secret_access_key=req['secret_key'],
    endpoint_url=req['endpoint'],
    region_name=req['region'],
)

if req['operation'] == 'upload':
    s3_client.upload_fileobj(sys.stdin.buffer, req['bucket'], req['object'],
                             ExtraArgs={'ContentType': req['content_type']})
    res = {'status': True}
    print(json.dumps(res))

elif req['operation'] == 'check':
    try:
        s3_client.head_object(Bucket=req['bucket'], Key=req['object'])
        exists = True
    except ClientError:
        exists = False
    res = {'exists': exists}
    print(json.dumps(res))

elif req['operation'] == 'get':
    response = s3_client.get_object(Bucket=req['bucket'], Key=req['object'])
    data = response['Body'].read()
    sys.stdout.buffer.write(data)

elif req['operation'] == 'delete':
    try:
        response = s3_client.delete_object(Bucket=req['bucket'], Key=req['object'])
        ok = True
    except ClientError:
        ok = False
    res = {'status': ok}
    print(json.dumps(res))


