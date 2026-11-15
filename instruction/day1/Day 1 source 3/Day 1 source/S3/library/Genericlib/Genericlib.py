import boto3
import json
from datetime import date
from datetime import datetime
from boto3.dynamodb.conditions import Key, Attr
import logging
from dateutil.parser import parse
import uuid

TBL_JOB_LOG = 'NT_Accelerate_JOB_LOG'
TBL_JOB_STATUS = 'NT_Accelarate_JOB_STATUS'
TBL_WATERMARKTABLE = 'NT_Acccelarate_WATERMARKTABLE'
###################GENERIC FUNCTIONS##############################################
def WriteLog(
        client,
        uuid,
        job_name,
        batch_id,
        run_date,
        #lastcheckpoint,
        src_count,
        trg_count,
        status,
        error_msg,
        start_run,
        end_run
    ):
    response = client.put_item(TableName=TBL_JOB_LOG,
                               Item={
                                     'ID': {'S': uuid},     
                                     'BATCH_ID': {'N': batch_id},
                                     'RUN_DATE': {'S': run_date},
                                     #'LAST_CHECKPOINT': {'S': lastcheckpoint},
                                     'SOURCE_COUNT': {'N': src_count},
                                     'TARGET_COUNT': {'N': trg_count},
                                     'PROCESS_STATUS': {'S': status},
                                     'ERROR_MSG': {'S': error_msg},
                                     'START_RUN': {'S': start_run},
                                     'END_RUN': {'S': end_run},
                                     'JOB_NAME': {'S': job_name}
                                    }
                              )
    return True

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
    
def Build_Predicate(columns,data_types, values):
    predicate = ""
    data_type=""
    column=""
    for i in range(len(columns)):
        column = columns[i]
        data_type = data_types[i].upper()
        value = values[i]
        
        if data_type == "STRING" or data_type == "DATETIME":
            predicate += column + " > " + "'" + value + "'" + " AND "
        elif data_type == "NUMBER":
            predicate += column + " > " + value  + " AND "
        
    predicate += "1=1"
    return predicate

def GenerateQueryString(job_name, region):
    client = boto3.resource('dynamodb', region_name=region)
    table = client.Table(TBL_WATERMARKTABLE)
    
    fe = Key('JOB_NAME').eq(job_name)
    pe = "ID, QUERY_STRING, COLUMN_NAMES, DATA_TYPES, DATA_VALUES"
    
    query_string = ""
    response = table.scan(
        FilterExpression=fe,
        ProjectionExpression=pe
        )
    if len(response['Items']) == 0: #No entry
        return False
    else:
        for x in response['Items']:
            id = x['ID']
            query_string = x['QUERY_STRING']
            columns = x['COLUMN_NAMES']
            data_types = x['DATA_TYPES']
            values = x['DATA_VALUES']
    predicate = Build_Predicate(columns, data_types, values)
    commpleted_query_string = query_string + " " + predicate
    return commpleted_query_string, id, columns, data_types, values
 
def UpdateWaterMarkValue(client, df, column_names, job_name, id):
     latest_values = []
     #Based on defined watermark columns, we get their latest values in source data frame and then update them in dynamodb table config WATERMARKTABLE
     for name in column_names:
         watermark_value = df.agg({name: "max"}).collect()[0][0]
         str_watermark_value = str(watermark_value)
         item  = {"S": str(str_watermark_value)}
         latest_values.append(item)
     
     response = client.update_item(
                                  TableName=TBL_WATERMARKTABLE,  
                                  Key = {
                                     'ID': {'N': str('0')},
                                     'JOB_NAME': {'S':job_name}
                                     
                                  },
                                  UpdateExpression="SET DATA_VALUES=:p_values", 
                                                        
                                  ExpressionAttributeValues={
                                                     ':p_values': {'L': latest_values}
                                                     
                                  },
                                  ReturnValues="UPDATED_NEW"
                             )    
     
     return True
   
def GetSecretDBSource(region):
    client = boto3.client("secretsmanager", region_name=region)
    get_secret_value_response = client.get_secret_value(
            SecretId= "SQLSource_Database_Connection_Info"
    )

    secret = get_secret_value_response['SecretString']
    secret = json.loads(secret)
    
    db_username = secret.get('db_username')
    db_password = secret.get('db_password')
    db_url = secret.get('db_url')
    jdbc_driver_name = secret.get('driver_name')
    return db_username, db_password, db_url, jdbc_driver_name