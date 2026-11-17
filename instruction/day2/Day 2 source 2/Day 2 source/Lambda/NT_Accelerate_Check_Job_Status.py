import json
import boto3
import datetime
from datetime import datetime
from boto3.dynamodb.conditions import Key, Attr

region = 'us-east-1'
TBL_JOB_STATUS = 'NT_Accelarate_JOB_STATUS'

'''
This function checks table NT_Accelarate_JOB_STATUS to see if exist Failed job in it or not
In the case exsitinng (return False), we can not continue running with LOAD_TYPE = NEW
'''
def lambda_handler(event, context):
    
    client = boto3.resource('dynamodb', region_name=region)
    table = client.Table(TBL_JOB_STATUS)
    
    fe = Key('PROCESS_STATUS').eq("FAILED")
    pe = "JOB_NAME"
    
    response = table.scan(
        FilterExpression=fe,
        ProjectionExpression=pe
        )
        
    if len(response['Items']) > 0:
        return {"FailedJobExisting":True}
    return {"FailedJobExisting":False}
    
