import json
import boto3
import datetime
from datetime import datetime
from boto3.dynamodb.conditions import Key, Attr


region = 'us-east-1'
dynamo_tbl = 'NT_Accelerate_MASTER_JOB_CONFIG'

def updateMasterJob_Status(
    masterjob_id,
    run_date,
    status
    ):
    dynamodb = boto3.client('dynamodb', region_name=region)
    response = dynamodb.update_item(
                                  TableName=dynamo_tbl,  
                                  Key = {
                                     'ID': {'N': str(masterjob_id)} 
                                  },
                                  UpdateExpression="SET LAST_RUN_DATE=:p_last_run_date, \
                                                        LAST_RUN_STATUS =:p_last_run_status",
                                  
                                  ExpressionAttributeValues={
                                                    ':p_last_run_date': {'S':str(run_date)},
                                                    ':p_last_run_status': {'S':str(status)}
                                                     
                                  },
                                  ReturnValues="UPDATED_NEW"
                             )
    return True



def lambda_handler(event, context):
    # TODO implement
    masterjob_id = event['p_masterjob_id']
    run_date = event['p_run_date']
    status = event['p_status']
    updateMasterJob_Status(masterjob_id,run_date,status)
    
    return True
    
    
