import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job

import boto3
import json
from datetime import date
from datetime import datetime
from boto3.dynamodb.conditions import Key, Attr
import logging
from dateutil.parser import parse
import uuid
import Genericlib as gl


args = getResolvedOptions(sys.argv, ["JOB_NAME"])
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
args = getResolvedOptions(sys.argv, ['JOB_NAME','p_job_name','p_run_date', 'p_batch_id', 'p_region', 'p_is_incremental_load', 'p_catalog_conn', 'p_src_databaseName', 'p_src_tableName', 'p_tar_databaseName', 'p_tar_tablename'])
job.init(args["JOB_NAME"], args)

#Get parameter
var_job_name = args['p_job_name']
var_run_date = args['p_run_date']
var_batch_id = args['p_batch_id']
var_region = args['p_region']
var_is_incremental_load = args['p_is_incremental_load'] #'FULLLOAD or INCREMENTAL_LOAD'
var_catalog_conn = args['p_catalog_conn']
var_src_databaseName = args['p_src_databaseName']
var_src_tableName = args['p_src_tableName']
var_tar_databaseName = args['p_tar_databaseName']
var_tar_tablename = args['p_tar_tablename']


'''###################GENERIC FUNCTIONS##############################################'''
'''
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
         print(str_watermark_value)
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


def GetSecretDBSource():
    client = boto3.client("secretsmanager", region_name="us-east-1")
    get_secret_value_response = client.get_secret_value(
            SecretId="SQLSource_Database_Connection_Info"
    )

    secret = get_secret_value_response['SecretString']
    secret = json.loads(secret)
    
    db_username = secret.get('db_username')
    db_password = secret.get('db_password')
    db_url = secret.get('db_url')
    jdbc_driver_name = secret.get('driver_name')
    return db_username, db_password, db_url, jdbc_driver_name
'''
'''##############################MAIN#####################################################'''


dynamodb = boto3.client('dynamodb', region_name=var_region)
start_run = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
end_run = ""

src_count = 0
trg_count = 0
process_status = ""
id = uuid.uuid1()
destination_path = var_tar_databaseName + var_tar_tablename +"/" + datetime.now().strftime("%Y-%m-%d")

if var_is_incremental_load.upper() == 'FALSE': #FULLLOAD
    try:
        DataSource0 = glueContext.create_dynamic_frame.from_catalog(database = var_src_databaseName, table_name = var_src_tableName, transformation_ctx = "DataSource0")
        src_count = DataSource0.count()
        trg_count = DataSource0.count()
        
        DataSink0 = glueContext.write_dynamic_frame.from_options(frame = DataSource0, format_options = {"compression": "snappy"}, connection_type = "s3", format = "glueparquet", connection_options = {"path": destination_path, "partitionKeys": []}, transformation_ctx = "DataSink0")    
        process_status = "SUCCEEDED"
        end_run = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
        gl.WriteLog(dynamodb,str(id), var_job_name, str(var_batch_id), var_run_date,str(src_count),str(trg_count), process_status,"",start_run,end_run)
        gl.UpdateJobStatus(dynamodb, var_job_name, str(var_batch_id), var_run_date, process_status,"")
    except Exception as e:
        error_msg = getattr(e, 'message', repr(e))
        process_status = "FAILED"
        end_run = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
        gl.WriteLog(dynamodb,str(id), var_job_name, str(var_batch_id), var_run_date,str(src_count),str(trg_count), process_status,error_msg,start_run,end_run)
        gl.UpdateJobStatus(dynamodb, var_job_name, str(var_batch_id), var_run_date, process_status,error_msg)
        sys.exit(0)
else: #INCREMENTAL_LOAD
    try:
        db_username, db_password, db_url, jdbc_driver_name = gl.GetSecretDBSource(var_region)
        #should use "()"" to avoid exceptional error
        commpleted_query_string, id, column_names, data_types, values = gl.GenerateQueryString(var_job_name, var_region)
        query = "(" + commpleted_query_string + ") as result"
        DataSource0 = spark.read.format("jdbc").option("url", db_url).option("driver", jdbc_driver_name).option("dbtable", query).option("user", db_username).option("password", db_password).load()
        
        #Convert dataframe to DynamicFrame
        dfSource = DynamicFrame.fromDF(DataSource0, glueContext, "mapped_datasource0")
        DataSink0 = glueContext.write_dynamic_frame.from_options(frame = dfSource, format_options = {"compression": "snappy"}, connection_type = "s3", format = "glueparquet", connection_options = {"path": destination_path, "partitionKeys": []}, transformation_ctx = "DataSink0")
        src_count = dfSource.count()
        trg_count = dfSource.count()
            
        if DataSource0.count() > 0:
            gl.UpdateWaterMarkValue(dynamodb, DataSource0, column_names, var_job_name, id)
        
        process_status = "SUCCEEDED"    
        end_run = datetime.now().strftime("%d/%m/%Y %H:%M:%S")    
        gl.WriteLog(dynamodb,str(id), var_job_name, str(var_batch_id), var_run_date,str(src_count),str(trg_count), process_status,"",start_run,end_run)
        gl.UpdateJobStatus(dynamodb, var_job_name, str(var_batch_id), var_run_date, process_status,"")
    except Exception as e:
        error_msg = getattr(e, 'message', repr(e))
        process_status = "FAILED"
        end_run = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
        gl.WriteLog(dynamodb,str(id), var_job_name, str(var_batch_id), var_run_date,str(src_count),str(trg_count), process_status,error_msg,start_run,end_run)
        gl.UpdateJobStatus(dynamodb, var_job_name, str(var_batch_id), var_run_date, process_status,error_msg)
        sys.exit(0)
job.commit()