# Troubleshooting

## Connection Issues

### `ConnectTimeoutError: Connection timed out`

**Symptom**: Databricks notebook can't connect to Trino.

**Cause**: Security group doesn't allow inbound traffic on Trino's HTTPS port from Databricks IPs.

**Fix**:
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-XXXXX \
  --protocol tcp \
  --port 9443 \
  --cidr YOUR_DATABRICKS_NAT_CIDR/24
```

### `Access Denied: Invalid Databricks token (HTTP 401)`

**Symptom**: Connection fails with "invalid token".

**Cause**: The Databricks API token is expired, revoked, or the workspace URL is wrong.

**Fix**:
1. Verify the token works: `curl -H "Authorization: Bearer dapi..." https://your-workspace.cloud.databricks.com/api/2.0/preview/scim/v2/Me`
2. Check `databricks.host` in `password-authenticator.properties` matches your workspace
3. Ensure Trino can reach the Databricks API (HTTPS egress to `*.cloud.databricks.com:443`)

### `Access Denied: Identity mismatch`

**Symptom**: Token is valid but connection is rejected because the claimed username doesn't match.

**Cause**: The `user=` parameter doesn't match the email associated with the token.

**Fix**: Use `spark.sql("SELECT current_user()").collect()[0][0]` to get the correct username.

## Query Issues

### Queries hang / timeout

**Symptom**: Connection works, `SELECT current_user` might work, but `SHOW CATALOGS` or data queries hang.

**Cause**: `internal-communication.shared-secret` mismatch between coordinator and workers. The coordinator can't dispatch work to workers because their JWT tokens are rejected.

**Diagnosis**:
```bash
# On the coordinator, check for internal auth errors:
sudo grep "Internal authentication failed" /var/log/trino/server.log | tail -5

# Check worker HTTP log — look for 401s from worker IPs:
sudo tail -50 /var/log/trino/http-request.log | grep "401"
```

**Fix**: Set the **same** `internal-communication.shared-secret` on ALL nodes and restart Trino on ALL nodes:
```bash
# Generate once:
SECRET=$(openssl rand -base64 32)

# Apply to all nodes via SSM:
aws ssm send-command --instance-ids i-coord i-worker1 i-worker2 \
  --document-name AWS-RunShellScript \
  --parameters "{\"commands\":[
    \"grep -q shared-secret /etc/trino/conf/config.properties && sudo sed -i 's/internal-communication.shared-secret=.*/internal-communication.shared-secret=$SECRET/' /etc/trino/conf/config.properties || echo 'internal-communication.shared-secret=$SECRET' | sudo tee -a /etc/trino/conf/config.properties\",
    \"sudo kill \\$(pgrep -f io.trino.server.TrinoServer) && sleep 5 && sudo -u trino /usr/lib/trino/bin/launcher start --etc-dir /etc/trino/conf\"
  ]}"
```

### `NO_NODES_AVAILABLE`

**Symptom**: Query fails immediately with "no nodes available".

**Cause**: Workers can't register with the coordinator (discovery service rejects them).

**Fix**: Same as above — shared secret mismatch. Also verify `discovery.uri` in worker config points to the coordinator's internal hostname and HTTP port.

## Plugin Loading Issues

### `authenticators were not loaded`

**Symptom**: Trino starts but password auth doesn't work. Log shows authenticators not loaded.

**Cause**: `password-authenticator.properties` not found or plugin JAR not in the right directory.

**Fix**:
```bash
# Verify plugin directory exists and has the JAR
ls -la /usr/lib/trino/plugin/databricks-auth/

# Verify password-authenticator.properties is in the right place
cat /etc/trino/conf/password-authenticator.properties

# Check Trino log for plugin loading messages
sudo grep -i "databricks\|authenticator\|plugin" /var/log/trino/server.log | tail -20
```

### `UnsupportedClassVersionError` or `class file has wrong version`

**Symptom**: Plugin fails to load with class version errors.

**Cause**: Plugin was compiled with a newer Java version than Trino is running.

**Fix**: Build the plugin on the same machine that runs Trino (use `deploy/emr/build_and_deploy.sh`), or ensure your local Java version is <= Trino's Java version. The plugin targets Java 21 bytecode, which runs on Java 21+.

## EMR-Specific Issues

### Trino port conflict with other EMR services

**Symptom**: Trino can't bind to port 8443 (already in use by another EMR service).

**Fix**: Use a different port (e.g., 9443):
```bash
# In config.properties:
http-server.https.port=9443
```

### EMR Step logs not appearing in S3

**Symptom**: EMR Step completes but stdout/stderr not in S3.

**Cause**: EMR pushes logs to S3 asynchronously (every ~5 minutes).

**Fix**: Use SSM Run Command instead for immediate output:
```bash
aws ssm send-command --instance-ids i-XXXXX \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["your command here"]}'

# Get output immediately:
aws ssm get-command-invocation \
  --command-id "cmd-XXXXX" \
  --instance-id "i-XXXXX" \
  --query 'StandardOutputContent'
```
