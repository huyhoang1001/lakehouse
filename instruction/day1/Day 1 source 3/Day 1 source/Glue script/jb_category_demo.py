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
#import Genericlib as gl


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
        #gl.WriteLog(dynamodb,str(id), var_job_name, str(var_batch_id), var_run_date,str(src_count),str(trg_count), process_status,"",start_run,end_run)
        #gl.UpdateJobStatus(dynamodb, var_job_name, str(var_batch_id), var_run_date, process_status,"")
    except Exception as e:
        error_msg = getattr(e, 'message', repr(e))
        process_status = "FAILED"
        end_run = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
        #gl.WriteLog(dynamodb,str(id), var_job_name, str(var_batch_id), var_run_date,str(src_count),str(trg_count), process_status,error_msg,start_run,end_run)
        #gl.UpdateJobStatus(dynamodb, var_job_name, str(var_batch_id), var_run_date, process_status,error_msg)
        sys.exit(0)
else: #INCREMENTAL_LOAD
    try:
        #db_username, db_password, db_url, jdbc_driver_name = gl.GetSecretDBSource(var_region)
        db_username = "ntadmin"
        db_password = "studygroup!#%"
        db_url = "jdbc:sqlserver://nt-accelarate.c1q8swyllcmw.us-east-1.rds.amazonaws.com:1433;databaseName=tickit"
        jdbc_driver_name = "com.microsoft.sqlserver.jdbc.SQLServerDriver"
        
        #should use "()"" to avoid exceptional error
        #commpleted_query_string, id, column_names, data_types, values = gl.GenerateQueryString(var_job_name, var_region)
        #query = "(" + commpleted_query_string + ") as result"
        query = "(select sellername, buyername, eventid, dateid, qtysold, pricepaid, commission, saletime from dbo.sales where saletime = '1970-01-01') as result"
        DataSource0 = spark.read.format("jdbc").option("url", db_url).option("driver", jdbc_driver_name).option("dbtable", query).option("user", db_username).option("password", db_password).load()
        
        #Convert dataframe to DynamicFrame
        dfSource = DynamicFrame.fromDF(DataSource0, glueContext, "mapped_datasource0")
        DataSink0 = glueContext.write_dynamic_frame.from_options(frame = dfSource, format_options = {"compression": "snappy"}, connection_type = "s3", format = "glueparquet", connection_options = {"path": destination_path, "partitionKeys": []}, transformation_ctx = "DataSink0")
        src_count = dfSource.count()
        trg_count = dfSource.count()
            
        if DataSource0.count() > 0:
            print("")
            #gl.UpdateWaterMarkValue(dynamodb, DataSource0, column_names, var_job_name, id)
        
        process_status = "SUCCEEDED"    
        end_run = datetime.now().strftime("%d/%m/%Y %H:%M:%S")    
        #gl.WriteLog(dynamodb,str(id), var_job_name, str(var_batch_id), var_run_date,str(src_count),str(trg_count), process_status,"",start_run,end_run)
        #gl.UpdateJobStatus(dynamodb, var_job_name, str(var_batch_id), var_run_date, process_status,"")
    except Exception as e:
        error_msg = getattr(e, 'message', repr(e))
        process_status = "FAILED"
        end_run = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
        #gl.WriteLog(dynamodb,str(id), var_job_name, str(var_batch_id), var_run_date,str(src_count),str(trg_count), process_status,error_msg,start_run,end_run)
        #gl.UpdateJobStatus(dynamodb, var_job_name, str(var_batch_id), var_run_date, process_status,error_msg)
        sys.exit(0)
job.commit()