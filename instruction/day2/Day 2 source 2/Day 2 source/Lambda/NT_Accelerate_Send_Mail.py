import sys
import boto3
import datetime
from datetime import date
from datetime import datetime
import logging
import time
from boto3.dynamodb.conditions import Key

region = 'us-east-1'
TBL_JOB_STATUS = 'NT_Accelarate_JOB_STATUS'
TBL_MAIL_CONFIG = 'NT_Accelerate_Mail_Config'

def GetMailList(client):
    table = client.Table(TBL_MAIL_CONFIG)
    fe = Key('ID').eq(str("1"))
    pe = "SENDER, RECEIVER"
    response = table.scan(
         FilterExpression=fe,
         ProjectionExpression=pe
        )
    
    item = response['Items'][0]
    sender = item['SENDER']
    
    receivers = item['RECEIVER']
    return sender, receivers


def SendMail(content,sender, receivers):
    ses_client = boto3.client("ses", region_name=region)
    CHARSET = "UTF-8"
    
    
    #Get status for each email
    response = ses_client.get_identity_verification_attributes(
    Identities=receivers,)

    verified_email = receivers
    
    for key, value in response['VerificationAttributes'].items():
        email = key
        status = value.get("VerificationStatus")
        if status != "Success":
            verified_email.remove(email)
    
    response = ses_client.send_email(
        Destination={
            "ToAddresses":  verified_email,
        },
        Message={
            "Body": {
                "Html": {
                    "Charset": CHARSET,
                    "Data":  content,
                }
            },
            "Subject": {
                "Charset": CHARSET,
                "Data": "Daily run elt job, Data warehouse process",
            },
        },
        Source=sender,
    )

    
    '''
    Depend on customer's requirement. It could get all or just failed jobs
    '''
def GetJobStatus(client):
    table = client.Table(TBL_JOB_STATUS)
    fe = Key('PROCESS_STATUS').eq(str("FAILED"))|Key('PROCESS_STATUS').eq(str("SUCCEEDED"))
    pe = "JOB_NAME,PROCESS_STATUS, RUN_DATE,ERROR_MSG"
    response = table.scan(
         FilterExpression=fe,
         ProjectionExpression=pe
        )
    content = "<TABLE><TR><TH>JOB NAME</TH><TH>JOB STATUS</TH><TH>RUN DATE</TH><TH>ERROR</TH></TR>"    
    if len(response['Items']) > 0:
        for i in response['Items']:
            job_failed = '<TD>jb_'+i["JOB_NAME"] + "</TD><TD>" + i["PROCESS_STATUS"] + "</TD><TD>" + i["RUN_DATE"] + "</TD><TD>" + i["ERROR_MSG"] + "</TD>\n"
            content = content +'<TR>'+ job_failed +'</TR>'
    return content+"</TABLE>"


def lambda_handler(event, context):
    dynamodb = boto3.resource('dynamodb', region_name=region)
    content = GetJobStatus(dynamodb)
    if content.find('<TD>') > 0:
        content="<HTML><HEAD><style>table, th, td {  border: 1px solid black;  border-collapse: collapse;}th, td {  padding: 5px;  text-align: left;}</style></HEAD><BODY>This email to notify you that some ELT daily run jobs today <strong style='color:red'>FAILED</strong>. The job list detail below:<BR><BR>"+content+"<BR>Note: Please do not reply on this email.</BODY></HTML>"
        sender, receivers =  GetMailList(dynamodb)
        SendMail(content,sender, receivers)
    
    return True
