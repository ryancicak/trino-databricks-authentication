# trino-databricks-authentication

Trino password authenticator plugin that validates Databricks API tokens. When a user connects to Trino from a Databricks notebook, they pass their Databricks API token as the Trino password. The plugin calls the Databricks SCIM API to verify the token and extract the owner's email, which becomes the Trino principal.

The identity can't be spoofed. Trino validates the token server-side, and rejects the connection if the claimed username doesn't match the token owner.

No external dependencies. Just the JDK standard library and the Trino SPI.

## Background

Databricks Lakehouse Federation lets you query external engines like Trino. But Trino only sees a `user` string that the client sets, so there's nothing stopping someone from claiming to be `admin@company.com`. This plugin fixes that by using the Databricks API token (which is cryptographically tied to a specific user) as proof of identity.

The flow:
1. Notebook gets the user's email via `current_user()` and their API token
2. Connects to Trino with email as user, token as password
3. Plugin calls `GET /api/2.0/preview/scim/v2/Me` with the token
4. Databricks returns the token owner's email
5. If it matches the claimed user, Trino sets the principal. If not, rejected.

## Building

Java 21+ and Maven 3.8+ required.

```bash
cd plugin
mvn clean package
```

Output: `plugin/target/trino-databricks-auth-1.0.0.jar` (about 9 KB)

For EMR, there's a script that handles everything including auto-detecting the Trino SPI version. See `deploy/emr/build_and_deploy.sh`.

## Deploying

### Install the plugin

```bash
sudo mkdir -p /usr/lib/trino/plugin/databricks-auth/
sudo cp plugin/target/trino-databricks-auth-1.0.0.jar /usr/lib/trino/plugin/databricks-auth/
```

### Create `password-authenticator.properties`

Put this in your Trino config directory (e.g. `/etc/trino/conf/`):

```properties
password-authenticator.name=databricks
databricks.host=https://your-workspace.cloud.databricks.com
databricks.cache-ttl-sec=300
databricks.cache-max=1000
```

### Update `config.properties`

```properties
http-server.authentication.type=PASSWORD
http-server.authentication.allow-insecure-over-http=true

# generate with: openssl rand -base64 32
# MUST be the same on all nodes or queries will hang
internal-communication.shared-secret=your-secret-here

http-server.https.enabled=true
http-server.https.port=9443
http-server.https.keystore.path=/etc/trino/ssl/keystore.jks
http-server.https.keystore.key=your-keystore-password
```

Then restart Trino.

### Multi-node clusters

The `internal-communication.shared-secret` has to be identical on the coordinator and every worker. If it's not, the coordinator can't dispatch work to workers and queries hang forever with no error message. This one burned a lot of time to figure out. See `docs/troubleshooting.md` if you run into it.

## Usage (Databricks notebook)

```python
%pip install trino -q

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

from trino.dbapi import connect
from trino.auth import BasicAuthentication

username = spark.sql("SELECT current_user()").collect()[0][0]
token = dbutils.notebook.entry_point.getDbutils().notebook().getContext().apiToken().get()

conn = connect(
    host="your-trino-host",
    port=9443,
    user=username,
    http_scheme="https",
    auth=BasicAuthentication(username, token),
    verify=False,  # self-signed cert; use True in production
)

cursor = conn.cursor()
cursor.execute("SHOW CATALOGS")
for row in cursor.fetchall():
    print(row[0])
```

## Configuration

`password-authenticator.properties`:

- `databricks.host` (required): your workspace URL, e.g. `https://myworkspace.cloud.databricks.com`
- `databricks.cache-ttl-sec` (default 300): how long to cache a validated token before re-checking
- `databricks.cache-max` (default 1000): max cached tokens

## Repo layout

```
plugin/              Java plugin source + pom.xml
deploy/emr/          Build-on-EMR and configure scripts
deploy/generic/      Install script for any Trino cluster
config/              Config file templates
notebooks/           Databricks notebook examples
docs/                Architecture, EMR setup guide, troubleshooting
```

## Why zero dependencies?

Trino loads each plugin in its own classloader. If you bundle Guava or Jackson in your plugin JAR, they can conflict with the versions Trino uses internally. You get `ClassNotFoundException` at runtime even though everything compiled fine. We hit this and it was painful to debug.

Instead of shading or fighting classloader issues, the plugin just uses `ConcurrentHashMap` for caching, `java.util.regex` for JSON parsing (we only need one field), and `java.net.http.HttpClient` for the SCIM call. No conflicts possible.

## Tested with

- Trino 438 through 476 (EMR 7.x)
- Java 21, 24, 25
- Databricks on AWS (should work with any Databricks workspace that has the SCIM API)

## License

Apache 2.0
