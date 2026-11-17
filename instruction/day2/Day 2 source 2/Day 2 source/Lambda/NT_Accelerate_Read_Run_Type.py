import json
import boto3
import datetime
from datetime import datetime
from boto3.dynamodb.conditions import Key, Attr
'''
This function is used to read run type from table NT_Accelerate_MASTER_JOB_CONFIG. There are 2 run types: NEW and RERUN
- NEW: run new master job, when run new master job. we will get current date and batchID = batchID + 1
- RERUN: in the case master job failed and need to rerun. When rerun, we need to get run_date and batchID in this table as well
'''
region = 'us-east-1'
dynamo_tbl = 'NT_Accelerate_MASTER_JOB_CONFIG'

def Read_Run_Type(var_master_job_id):
    dynamodb = boto3.resource('dynamodb', region_name=region)
    table = dynamodb.Table(dynamo_tbl)
    response = table.query(KeyConditionExpression=Key('ID').eq(var_master_job_id))
    
    flag = False
    if len(response['Items']) == 0:
        flag = False # exit because not config yet
    else:
        flag = True
        for item in response['Items']:
            run_type = item['RUN_TYPE']
            run_date = item['RERUN_DATE']
            batch_id = int(item['BATCH_ID'])
    return flag, run_type, run_date, batch_id  


def updateBatchId(var_master_job_id,
    batch_id
    ):
    dynamodb = boto3.client('dynamodb', region_name=region)
    response = dynamodb.update_item(
                                  TableName=dynamo_tbl,  
                                  Key = {
                                     'ID': {'N': str(var_master_job_id)} 
                                  },
                                  UpdateExpression="SET BATCH_ID=:p_batch_id",
                                  ExpressionAttributeValues={
                                                    ':p_batch_id': {'N':str(batch_id)}
                                                     
                                  },
                                  ReturnValues="UPDATED_NEW"
                             )
    return True


def isValidDate(date):
    try:
        return bool(datetime.strptime(date, '%Y-%m-%d'))
    except ValueError:
        return False
        
    
def lambda_handler(event, context):
    # TODO implement
    var_master_job_id = event['p_masterjob_id']
    #read info from NT_Accelerate_MASTER_JOB_CONFIG
    flag, run_type, run_date, batch_id = Read_Run_Type(var_master_job_id)
    
    if flag == True:
        if run_type == 'NEW':    #If run new 
            run_date = datetime.now().strftime("%Y-%m-%d")
            batch_id = batch_id + 1
            updateBatchId(var_master_job_id,batch_id)
        else:  #if rerun
            if isValidDate(run_date) == False: 
                flag = True
            
    return {"flag":flag, "run_type":run_type, "run_date":run_date, "batch_id":str(batch_id)}
