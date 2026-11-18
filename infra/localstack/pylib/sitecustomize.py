"""Local Glue test shim: route boto3 calls to LocalStack.

The Glue 4.0 image ships boto3 1.24 / botocore 1.27, which predate the
AWS_ENDPOINT_URL environment variable, so we patch boto3 here instead.

Redirected services:
  * dynamodb        -- job log / status / watermark control tables
  * secretsmanager  -- the RDS JDBC credentials secret

For secretsmanager, when LOCAL_SECRET_JDBC_HOST is set the ``db_url`` returned
by GetSecretValue is rewritten so it is reachable from inside the Glue
container. The secret stored in LocalStack points at ``localhost:1433`` (the
host view); from a sibling container that address is the container itself, so
it must become ``host.docker.internal``. Encryption is also disabled because
the local SQL Server's self-signed certificate is rejected by the JDBC TLS
layer.

When LOCAL_SECRET_JDBC_USER is set the ``db_username`` is also rewritten. The
secret mirrors the RDS master user (``admin``), but the local Azure SQL Edge
container's master login is ``sa`` -- the local analogue of the RDS master
user. Mapping the secret onto it keeps the Glue scripts unmodified and needs
no additional SQL login.
"""
import json
import os
import re

_endpoint = os.environ.get("LOCALSTACK_ENDPOINT")
if _endpoint:
    import boto3

    _ROUTED = {"dynamodb", "secretsmanager"}
    _secret_host = os.environ.get("LOCAL_SECRET_JDBC_HOST")
    _secret_user = os.environ.get("LOCAL_SECRET_JDBC_USER")
    _orig_client = boto3.client
    _orig_resource = boto3.resource

    def _rewrite_secret(response):
        """Point the secret's db_url at the container-reachable host and,
        when configured, swap the username for the local SQL Server login."""
        if not _secret_host or not response.get("SecretString"):
            return response
        try:
            secret = json.loads(response["SecretString"])
        except (TypeError, ValueError):
            return response
        if _secret_user:
            secret["db_username"] = _secret_user
        url = secret.get("db_url")
        if url and "jdbc:sqlserver://" in url:
            url = re.sub(r"//(localhost|127\.0\.0\.1)(:\d+)", rf"//{_secret_host}\2", url)
            if "encrypt=" not in url:
                url += ";encrypt=false;trustServerCertificate=true"
            secret["db_url"] = url
        response["SecretString"] = json.dumps(secret)
        return response

    def _client(*args, **kwargs):
        service = args[0] if args else kwargs.get("service_name")
        if service in _ROUTED:
            kwargs.setdefault("endpoint_url", _endpoint)
            kwargs.setdefault("region_name", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
            kwargs.setdefault("aws_access_key_id", os.environ.get("AWS_ACCESS_KEY_ID", "test"))
            kwargs.setdefault("aws_secret_access_key", os.environ.get("AWS_SECRET_ACCESS_KEY", "test"))
        client = _orig_client(*args, **kwargs)
        if service == "secretsmanager" and _secret_host:
            _orig_get = client.get_secret_value

            def _get_secret_value(*a, **kw):
                return _rewrite_secret(_orig_get(*a, **kw))

            client.get_secret_value = _get_secret_value
        return client

    boto3.client = _client

    def _resource(*args, **kwargs):
        service = args[0] if args else kwargs.get("service_name")
        if service in _ROUTED:
            kwargs.setdefault("endpoint_url", _endpoint)
            kwargs.setdefault("region_name", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
        return _orig_resource(*args, **kwargs)

    boto3.resource = _resource
