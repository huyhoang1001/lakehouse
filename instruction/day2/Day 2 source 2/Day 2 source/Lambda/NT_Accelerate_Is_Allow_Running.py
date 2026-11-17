import json
import boto3
from boto3.dynamodb.conditions import Key, Attr

region = 'us-east-1'
dynamo_tbl = 'NT_Accelerate_JOB_CONFIG'
dynamo_tbl_log = 'NT_Accelerate_JOB_LOG'
dynamo_tbl_job_status = 'NT_Accelarate_JOB_STATUS'

#Get Job Name info from JOB CONFIG table
def Get_Job_Config_Info(job_name):
    dynamodb = boto3.resource('dynamodb', region_name=region)
    table = dynamodb.Table(dynamo_tbl)
    
    fe = Key('JOB_NAME').eq(job_name)
    pe = "JOB_NAME, CATALOG_CON, INCREMENTAL_LOAD, MULTIPLE_RUN, REGION_NAME, SRC_DBNAME, SRC_TBLNAME, TRG_DBNAME, TRG_TBLNAME,LAKEHOUSE_LOCATION,POSTSCRIPT,PRESCRIPT,TEMP_FOLDER,LAYER"
    
    response = table.scan(
        FilterExpression=fe,
        ProjectionExpression=pe
        )
        
    if len(response['Items']) == 0: 
        flag = False
    else:
        flag = True
    
    return flag, response

'''
This function checks if job ran in that day?
If it is single run and ran then STOP
Otherwise allow it running
'''
def Check_Job_Ran_In_Day(job_name, run_date):
    
    dynamodb = boto3.resource('dynamodb', region_name=region)
    table = dynamodb.Table(dynamo_tbl_log)      
    
    fe = Key('JOB_NAME').eq(job_name)&Key('RUN_DATE').eq(run_date)
    
    response = table.scan(
        FilterExpression=fe
        )
                
    if len(response['Items']) > 0 :
        return True
    return False
    
def Check_Job_Failed_Status(job_name):  
    dynamodb = boto3.resource('dynamodb', region_name=region)
    table = dynamodb.Table(dynamo_tbl_job_status)      
    
    fe = Key('JOB_NAME').eq(job_name)&Key('PROCESS_STATUS').eq("FAILED")
    
    response = table.scan(
        FilterExpression=fe
        )
                
    if len(response['Items']) > 0 :
        return True
    return False

def Delete_Failed_Job_Item(job_name):
    dynamodb = boto3.resource('dynamodb', region_name=region)
    table = dynamodb.Table(dynamo_tbl_job_status) 
    
    response = table.delete_item(
        Key={
            'JOB_NAME': str(job_name)
        }
    )
    return True

def Check_Job_Ran_In_PrevRun(job_name):
    dynamodb = boto3.resource('dynamodb', region_name=region)
    table = dynamodb.Table(dynamo_tbl_job_status)      
    
    fe = Key('JOB_NAME').eq(job_name)
    
    response = table.scan(
        FilterExpression=fe
        )
                
    if len(response['Items']) > 0 :
        return True
    return False
    
'''
This function is to check if job is Single Run or Multiple run
In the case if it is single run and ran in the day, STOP. Otherwise allow running
In the case if it is multiple run, always allow running
'''

def lambda_handler(event, context):
    
    var_job_name = event["p_job_name"]
    var_run_date = event["p_run_date"]
    var_run_type = event["p_run_type"]
    
    #Get Job config info
    flag, response = Get_Job_Config_Info(var_job_name)
    
    
    var_catalog_con=""
    var_incremental_load=""
    var_multiple_run=""
    var_region=""
    var_src_db=""
    var_scr_table=""
    var_trg_db=""
    var_trg_table=""
    var_is_ran = ""
    var_lakehouse_location =""
    var_postscript = ""
    var_prescript = ""
    var_tempfolder = ""
    var_layer = ""
    if flag == True:
        for item in response['Items']:
            var_layer = item['LAYER']
            if var_layer.upper() == "STAGING":
                var_catalog_con = ""
                var_incremental_load = item['INCREMENTAL_LOAD']
                var_multiple_run = item['MULTIPLE_RUN']
                var_region = item['REGION_NAME']
                var_src_db = item['SRC_DBNAME']
                var_scr_table = item['SRC_TBLNAME']
                var_trg_db = item['TRG_DBNAME']
                var_trg_table = item['TRG_TBLNAME']
                var_lakehouse_location = ""
                var_postscript = ""
                var_prescript = ""
                var_tempfolder = ""
            elif var_layer.upper() == "LAKEHOUSE":    
                var_catalog_con = ""   
                var_incremental_load = ""
                var_multiple_run = item['MULTIPLE_RUN']
                var_region = item['REGION_NAME']
                var_src_db = item['SRC_DBNAME']
                var_scr_table = item['SRC_TBLNAME']
                var_trg_db = item['TRG_DBNAME']
                var_trg_table = item['TRG_TBLNAME']
                var_lakehouse_location = item['LAKEHOUSE_LOCATION']
                var_postscript = ""
                var_prescript = ""
                var_tempfolder = ""
            else:    
                var_catalog_con = item['CATALOG_CON']   
                var_incremental_load = ""
                var_multiple_run = item['MULTIPLE_RUN']
                var_region = item['REGION_NAME']
                var_src_db = item['SRC_DBNAME']
                var_scr_table = item['SRC_TBLNAME']
                var_trg_db = item['TRG_DBNAME']
                var_trg_table = item['TRG_TBLNAME']
                var_lakehouse_location = ""
                var_postscript = item['POSTSCRIPT']
                var_prescript = item['PRESCRIPT']
                var_tempfolder = item['TEMP_FOLDER']
            #If job failed in previous run, delete it in JOB STATUS table and rerun
            #If succcess, nothing to do
            if var_run_type == "RERUN": #Rerun and job failed in previous run. Delete item in JOB CONFIG and run again
                if Check_Job_Failed_Status(var_job_name) == True:
                    Delete_Failed_Job_Item(var_job_name)
                    var_is_ran = "No"
                elif Check_Job_Ran_In_PrevRun(var_job_name)==False: #Job not run in previous run yet
                    var_is_ran = "No"
                else: #Job run succce
                    var_is_ran = "Yes" # rerun but JOB ran success in previous run-> Nothing to do
            else: #NEW   
                if var_multiple_run.upper()=='FALSE': #If single run
                    if Check_Job_Ran_In_Day(var_job_name,var_run_date)==True: # Job ran in day. Nothing
                        var_is_ran = "Yes"
                    else:
                        var_is_ran = "No"
                else:
                    var_is_ran = "No"
    return {"is_ran": var_is_ran, "var_job_name":var_job_name, "var_run_date": var_run_date, "var_catalog_con": var_catalog_con, "var_incremental_load":var_incremental_load, "var_multiple_run": var_multiple_run, "var_region": var_region, "var_src_db":var_src_db, "var_scr_table":var_scr_table, "var_trg_db":var_trg_db, "var_trg_table":var_trg_table, "var_lakehouse_location":var_lakehouse_location, "var_postscript": var_postscript,"var_prescript":var_prescript,"var_tempfolder":var_tempfolder}
    