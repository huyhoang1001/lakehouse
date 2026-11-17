import json
import boto3
import datetime
from datetime import datetime
from boto3.dynamodb.conditions import Key, Attr

region = 'us-east-1'
TBL_JOB_STATUS = 'NT_Accelarate_JOB_STATUS'

def Delete_Item(table,var_job_name):
    response = table.delete_item(
        Key={
            'JOB_NAME': var_job_name
        }
    )
    return True
    

'''
This function is to check if Job reruns?
A job reruns when it runs failed not runing in previous run
'''
def lambda_handler(event, context):
    var_job_name = event['JobName']
    flag = False
    
    dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
    table = dynamodb.Table(TBL_JOB_STATUS)
    response = table.query(
            KeyConditionExpression=Key('JOB_NAME').eq(var_job_name)
        )
    '''If not exist in JOB STATUS then run it again'''
    if len(response['Items'])==0:
        flag = True
    
    
    fe = Key('JOB_NAME').eq(var_job_name)&Key('PROCESS_STATUS').eq("FAILED")
    pe = "JOB_NAME"
    
    response = table.scan(
        FilterExpression=fe,
        ProjectionExpression=pe
        )
    
    '''If exist in JOB STATUS and status = FAILED then run it again'''
    if len(response['Items']) >0:
        Delete_Item(table,var_job_name)
        flag = True
        
    return {"flag":flag}
