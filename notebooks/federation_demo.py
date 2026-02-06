# Databricks notebook source
# MAGIC %md
# MAGIC # Lakehouse Federation Demo: Databricks + Trino + Iceberg
# MAGIC
# MAGIC This notebook demonstrates:
# MAGIC 1. **Verified identity** — Databricks token passed to Trino, validated via SCIM API
# MAGIC 2. **Federated queries** — Databricks Serverless querying Iceberg tables through Trino
# MAGIC 3. **Iceberg features** — Merge-on-Read tables, partition evolution, row-level deletes
# MAGIC
# MAGIC ## Architecture
# MAGIC ```
# MAGIC ┌──────────────────────┐         ┌───────────────────┐        ┌──────────────────┐
# MAGIC │ Databricks Serverless│  HTTPS  │   Trino on EMR    │  S3    │  Iceberg Tables  │
# MAGIC │                      │────────>│                   │───────>│  (Glue Catalog)  │
# MAGIC │  Token: dapi...      │  :9443  │  Auth Plugin      │        │                  │
# MAGIC │  User:  alice@co.com │         │  validates token  │        │  orders_mor      │
# MAGIC └──────────────────────┘         │  via Databricks   │        │  events_partevo  │
# MAGIC                                  │  SCIM API         │        └──────────────────┘
# MAGIC                                  └───────────────────┘
# MAGIC ```

# COMMAND ----------

%pip install trino -q

# COMMAND ----------

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

from trino.dbapi import connect
from trino.auth import BasicAuthentication

# ── Configuration ──────────────────────────────────────────
TRINO_HOST = "your-trino-host.compute.amazonaws.com"  # <-- CHANGE THIS
TRINO_PORT = 9443
# ───────────────────────────────────────────────────────────

# Get verified Databricks identity
username = spark.sql("SELECT current_user()").collect()[0][0]
token = dbutils.notebook.entry_point.getDbutils().notebook().getContext().apiToken().get()

print(f"Databricks user: {username}")

conn = connect(
    host=TRINO_HOST,
    port=TRINO_PORT,
    user=username,
    http_scheme="https",
    auth=BasicAuthentication(username, token),
    verify=False,
)
cursor = conn.cursor()

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. Verify Identity
# MAGIC
# MAGIC Trino independently verified our Databricks token. The principal is our real email.

# COMMAND ----------

cursor.execute("SELECT current_user")
trino_user = cursor.fetchone()[0]
print(f"Trino principal: {trino_user}")
assert trino_user == username, "Identity mismatch!"
print("Identity verified: Databricks user == Trino principal")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. List Catalogs
# MAGIC
# MAGIC Trino can query multiple data sources through catalogs.

# COMMAND ----------

cursor.execute("SHOW CATALOGS")
print("Available Catalogs:")
for row in cursor.fetchall():
    print(f"  {row[0]}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. Query Iceberg Tables
# MAGIC
# MAGIC Query Iceberg tables managed by AWS Glue, accessed through Trino.

# COMMAND ----------

# Query a Merge-on-Read Iceberg table
cursor.execute("""
    SELECT *
    FROM iceberg_glue.federation_demo_db_ryan.orders_mor
    ORDER BY order_id
""")

print("Orders (Merge-on-Read Iceberg table):")
print("-" * 60)
for row in cursor.fetchall():
    print(row)

# COMMAND ----------

# Query a partition-evolved Iceberg table
cursor.execute("""
    SELECT *
    FROM iceberg_glue.federation_demo_db_ryan.events_partevo
    ORDER BY event_id
""")

print("Events (Partition Evolution Iceberg table):")
print("-" * 60)
for row in cursor.fetchall():
    print(row)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. Security: Identity Cannot Be Spoofed
# MAGIC
# MAGIC If someone tries to claim a different identity, Trino rejects it.

# COMMAND ----------

# This would FAIL: token doesn't match the claimed user
try:
    bad_conn = connect(
        host=TRINO_HOST,
        port=TRINO_PORT,
        user="fake@evil.com",  # Not the token owner!
        http_scheme="https",
        auth=BasicAuthentication("fake@evil.com", token),
        verify=False,
    )
    bad_cursor = bad_conn.cursor()
    bad_cursor.execute("SELECT 1")
    print("ERROR: This should not succeed!")
except Exception as e:
    print(f"Correctly rejected: {e}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## How It Works
# MAGIC
# MAGIC ```
# MAGIC 1. Databricks Notebook                    2. Trino Server
# MAGIC    ┌─────────────────────┐                   ┌──────────────────┐
# MAGIC    │ username = current_user()               │                  │
# MAGIC    │ token = apiToken()   │                   │                  │
# MAGIC    │                      │                   │                  │
# MAGIC    │ connect(user, token) ├──────────────────>│ Receive creds    │
# MAGIC    │                      │                   │                  │
# MAGIC    │                      │  3. Databricks    │ Call SCIM API ───┤──> GET /scim/v2/Me
# MAGIC    │                      │     API           │                  │    Bearer <token>
# MAGIC    │                      │                   │ Verify user ←────┤<── "alice@co.com"
# MAGIC    │                      │                   │                  │
# MAGIC    │ query runs as        │<──────────────────│ Set principal    │
# MAGIC    │ verified alice@co.com│                   │ = alice@co.com   │
# MAGIC    └─────────────────────┘                   └──────────────────┘
# MAGIC ```
# MAGIC
# MAGIC **Why it's unspoofable:**
# MAGIC - `current_user()` is set by Databricks — users can't override it
# MAGIC - The API token is cryptographically tied to the user
# MAGIC - Trino independently validates the token (zero trust)
# MAGIC - Mismatched user + token = connection rejected

# COMMAND ----------

cursor.close()
conn.close()
print("Demo complete.")
