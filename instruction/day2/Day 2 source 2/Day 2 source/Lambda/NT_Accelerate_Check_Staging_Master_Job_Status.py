import json
import boto3
import datetime
from datetime import datetime
from boto3.dynamodb.conditions import Key, Attr

region = 'us-east-1'
TBL_MASTER_JOB_CONFIG = 'NT_Accelerate_MASTER_JOB_CONFIG'

'''
This function is to check if staging master job ran successfully in day
'''
def lambda_handler(event, context):
    var_run_date = event['p_run_date']
    flag = False
    
    dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
    table = dynamodb.Table(TBL_MASTER_JOB_CONFIG)
    '''
    response = table.query(
            KeyConditionExpression=Key('ID').eq(1)&Key('LAST_RUN_DATE').eq(var_run_date)&Key('LAST_RUN_STATUS').eq("SUCCEEDED")
        )
    '''
    
    fe = Key('ID').eq(1)&Key('LAST_RUN_DATE').eq(var_run_date)&Key('LAST_RUN_STATUS').eq("SUCCEEDED")
    pe = "ID"
    
    response = table.scan(
        FilterExpression=fe,
        ProjectionExpression=pe
        )
    
    if len(response['Items']) >0: #Ran in date
        flag = True
    
    return {"flag":flag}
    