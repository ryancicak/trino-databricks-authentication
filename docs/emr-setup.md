# EMR Setup Guide

Step-by-step guide to deploy the Databricks auth plugin on an AWS EMR cluster running Trino.

## Prerequisites

- An EMR cluster with Trino (EMR 7.x recommended)
- AWS CLI configured with permissions for EMR, S3, and SSM
- A Databricks workspace URL
- Your EMR cluster's master node public hostname

## Step 1: Build and Upload Source

On your local machine:

```bash
# Package the plugin source
cd trino-databricks-auth
tar czf /tmp/plugin-source.tar.gz plugin/

# Upload to S3
aws s3 cp /tmp/plugin-source.tar.gz s3://your-bucket/trino-auth/plugin-source.tar.gz
aws s3 cp deploy/emr/build_and_deploy.sh s3://your-bucket/trino-auth/build_and_deploy.sh
aws s3 cp deploy/emr/configure_auth.sh s3://your-bucket/trino-auth/configure_auth.sh
```

## Step 2: Build and Deploy Plugin

Run the build script on the EMR master node:

```bash
aws emr add-steps --cluster-id j-XXXXX --steps \
  "Type=CUSTOM_JAR,\
   Name=BuildDeployAuth,\
   Jar=s3://us-west-2.elasticmapreduce/libs/script-runner/script-runner.jar,\
   Args=[s3://your-bucket/trino-auth/build_and_deploy.sh,s3://your-bucket/trino-auth/plugin-source.tar.gz],\
   ActionOnFailure=CONTINUE" \
  --region us-west-2
```

Wait for the step to complete:

```bash
aws emr describe-step --cluster-id j-XXXXX --step-id s-XXXXX \
  --query 'Step.Status.State' --output text
```

## Step 3: Configure Authentication

**Important**: This must run on ALL nodes with the SAME shared secret.

```bash
# Get all instance IDs
INSTANCES=$(aws emr list-instances --cluster-id j-XXXXX \
  --query 'Instances[*].Ec2InstanceId' --output text)

# Generate a shared secret (once!)
SECRET=$(openssl rand -base64 32)
echo "Save this secret: $SECRET"

# Configure all nodes via SSM
aws ssm send-command \
  --instance-ids $INSTANCES \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[
    \"aws s3 cp s3://your-bucket/trino-auth/configure_auth.sh /tmp/configure_auth.sh\",
    \"chmod +x /tmp/configure_auth.sh\",
    \"bash /tmp/configure_auth.sh https://your-workspace.cloud.databricks.com $SECRET 9443\"
  ]}" \
  --region us-west-2
```

## Step 4: Open Security Group

Allow Databricks Serverless to reach Trino's HTTPS port:

```bash
# Find the EMR security group
SG_ID=$(aws ec2 describe-instances \
  --instance-ids $(aws emr list-instances --cluster-id j-XXXXX \
    --instance-group-types MASTER \
    --query 'Instances[0].Ec2InstanceId' --output text) \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
  --output text)

# Add rule for Databricks serverless IPs
# Check your Databricks region's NAT gateway IPs in the NCC config
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 9443 \
  --cidr YOUR_DATABRICKS_NAT_CIDR/24
```

To find your Databricks Serverless IP range:
1. Go to Databricks workspace > Admin Settings > Networking
2. Look at the Network Connectivity Configuration (NCC) stable NAT IPs

## Step 5: Test from Databricks

In a Databricks notebook:

```python
%pip install trino -q

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

from trino.dbapi import connect
from trino.auth import BasicAuthentication

username = spark.sql("SELECT current_user()").collect()[0][0]
token = dbutils.notebook.entry_point.getDbutils().notebook().getContext().apiToken().get()

conn = connect(
    host="ec2-xx-xx-xx-xx.us-west-2.compute.amazonaws.com",  # EMR master public DNS
    port=9443,
    user=username,
    http_scheme="https",
    auth=BasicAuthentication(username, token),
    verify=False,
)

cursor = conn.cursor()
cursor.execute("SHOW CATALOGS")
for row in cursor.fetchall():
    print(row[0])
```

## Troubleshooting

See [troubleshooting.md](troubleshooting.md) for common issues and solutions.
