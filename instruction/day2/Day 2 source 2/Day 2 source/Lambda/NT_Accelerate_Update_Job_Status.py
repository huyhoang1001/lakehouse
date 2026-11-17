import json
import boto3
import datetime
from datetime import datetime
from boto3.dynamodb.conditions import Key, Attr

region = 'us-east-1'
TBL_JOB_STATUS = 'NT_Accelarate_JOB_STATUS'


def UpdateJobStatus(
        client,
        job_name,
        batch_id,
        run_date,
        status,
        error_msg
    ):
    response = client.put_item(TableName=TBL_JOB_STATUS,
                               Item={
                                     'JOB_NAME': {'S': job_name},
                                     'BATCH_ID': {'N': batch_id},
                                     'RUN_DATE': {'S': run_date},
                                     'PROCESS_STATUS': {'S': status},
                                     'ERROR_MSG': {'S': error_msg}
                                     }
                              )
    return True
    
def lambda_handler(event, context):
    var_job_name = event['JobName']
    var_batch_id = event['BatchId']
    var_run_date = event['RunDate']
    
    dynamodb = boto3.client('dynamodb', region_name=region)
    UpdateJobStatus(dynamodb, var_job_name,var_batch_id, var_run_date,"SUCCEEDED", "Job ran in day")
    
    return True
