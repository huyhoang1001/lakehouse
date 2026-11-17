import json
import boto3
import datetime
from datetime import datetime
from boto3.dynamodb.conditions import Key, Attr

region = 'us-east-1'
TBL_JOB_STATUS = 'NT_Accelarate_JOB_STATUS'

def lambda_handler(event, context):
    try:
        flag = False
        dynamodb = boto3.resource('dynamodb')
        table = dynamodb.Table(TBL_JOB_STATUS)
        response = table.scan()
        while flag is False:
            with table.batch_writer() as batch:
                for item in response['Items']:
                    batch.delete_item(
                             Key={
                             'JOB_NAME': item['JOB_NAME']
                             }
                         )
                flag = True
        print("Complete")
    except Exception as e:
       print (e)
    return True
