# Databricks notebook source
# MAGIC %md
# MAGIC # Trino Connection — Quickstart
# MAGIC
# MAGIC Minimal example: connect to Trino from Databricks using verified identity.

# COMMAND ----------

# Install the Trino Python client
%pip install trino -q

# COMMAND ----------

import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

from trino.dbapi import connect
from trino.auth import BasicAuthentication

# ── Configuration ──────────────────────────────────────────
TRINO_HOST = "your-trino-host.compute.amazonaws.com"  # <-- CHANGE THIS
TRINO_PORT = 9443                                      # <-- CHANGE THIS
# ───────────────────────────────────────────────────────────

# Get Databricks identity (cannot be spoofed)
username = spark.sql("SELECT current_user()").collect()[0][0]
token = dbutils.notebook.entry_point.getDbutils().notebook().getContext().apiToken().get()

print(f"Connecting as: {username}")

conn = connect(
    host=TRINO_HOST,
    port=TRINO_PORT,
    user=username,
    http_scheme="https",
    auth=BasicAuthentication(username, token),
    verify=False,  # Self-signed cert; set to True with a trusted cert
)

cursor = conn.cursor()

# COMMAND ----------

# Verify your identity in Trino
cursor.execute("SELECT current_user")
print(f"Trino sees you as: {cursor.fetchone()[0]}")

# COMMAND ----------

# List available catalogs
cursor.execute("SHOW CATALOGS")
print("Trino Catalogs:")
for row in cursor.fetchall():
    print(f"  {row[0]}")

# COMMAND ----------

cursor.close()
conn.close()
print("Done.")
