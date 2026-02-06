# Architecture

## Overview

This plugin bridges Databricks identity into Trino, enabling federated queries where Trino knows exactly who is making each request — with cryptographic proof.

```
┌─────────────────────────┐
│   Databricks Serverless │
│                         │
│  1. Get current_user()  │        ┌──────────────────────┐
│  2. Get API token       │  HTTPS │    Trino Cluster     │
│  3. Connect to Trino ───┼───────>│                      │
│     user = alice@co.com │  :9443 │  ┌────────────────┐  │
│     pass = dapi...      │        │  │  Auth Plugin   │  │
│                         │        │  │                │  │    ┌──────────────────┐
│                         │        │  │ 4. Validate ───┼──┼───>│ Databricks API   │
│                         │        │  │    token       │  │    │ GET /scim/v2/Me  │
│                         │        │  │              <─┼──┼────│ => alice@co.com  │
│                         │        │  │ 5. Set         │  │    └──────────────────┘
│                         │        │  │    principal   │  │
│  6. Query executes      │<───────│  └────────────────┘  │
│     as alice@co.com     │        │                      │
│                         │        │  ┌────────────────┐  │    ┌──────────────────┐
│                         │        │  │  Iceberg       │──┼───>│ S3 + Glue        │
│                         │        │  │  Connector     │  │    │ Iceberg Tables   │
│                         │        │  └────────────────┘  │    └──────────────────┘
└─────────────────────────┘        └──────────────────────┘
```

## Authentication Flow

1. **Token acquisition**: Databricks notebook calls `apiToken().get()` to retrieve the user's API token. This token is cryptographically bound to the user's identity and cannot be forged.

2. **Connection**: The Python `trino` client connects over HTTPS. The username (email) is sent as the HTTP Basic Auth username, and the Databricks API token is sent as the password.

3. **Token validation**: The plugin calls the Databricks SCIM API (`GET /api/2.0/preview/scim/v2/Me`) with the token as a Bearer token. Databricks returns the token owner's identity.

4. **Identity verification**: The plugin compares the SCIM-returned email against the claimed username. If they don't match, the connection is rejected. This prevents users from claiming to be someone else.

5. **Principal creation**: On success, the verified email becomes the Trino `BasicPrincipal`. This identity is used for:
   - Query logging and audit
   - Access control rules
   - Resource group assignment

## Why Zero External Dependencies?

Trino's plugin architecture uses an **isolated classloader** per plugin. Each plugin gets its own classpath, separate from Trino's internal classpath. This means:

- **Guava conflicts**: Trino bundles Guava internally. If your plugin also bundles Guava (even the same version), the classloader can load the wrong version for internal Trino classes that interact with plugin objects, causing `ClassNotFoundException` or `NoSuchMethodError`.

- **Jackson conflicts**: Same problem. Trino uses Jackson for internal JSON handling, and version mismatches in the plugin classloader cause class file version errors.

We solve this by using zero external dependencies:

| Need | Typical Library | Our Approach |
|------|----------------|--------------|
| Caching | Guava `LoadingCache` | `ConcurrentHashMap` with TTL check |
| JSON parsing | Jackson `ObjectMapper` | `Pattern.compile` regex for one field |
| HTTP client | Apache HttpClient | `java.net.http.HttpClient` (JDK 11+) |

The result is a tiny, conflict-free JAR that works across Trino versions.

## Multi-Node Cluster Architecture

```
                    ┌─────────────────────────┐
                    │      Coordinator        │
                    │  (port 8889 HTTP)       │
    External ──────>│  (port 9443 HTTPS)      │
    clients         │                         │
                    │  - Auth plugin loaded   │
                    │  - PASSWORD auth on HTTPS│
                    │  - Shared secret: ABC   │
                    └──────┬──────────┬───────┘
                           │          │
              Internal     │          │     Internal
              (HTTP+JWT)   │          │     (HTTP+JWT)
                           │          │
                    ┌──────┴───┐  ┌───┴──────┐
                    │ Worker 1 │  │ Worker 2 │
                    │ port 8889│  │ port 8889│
                    │          │  │          │
                    │ secret:  │  │ secret:  │
                    │   ABC    │  │   ABC    │
                    └──────────┘  └──────────┘
```

**Critical**: The `internal-communication.shared-secret` must be **identical** on all nodes. The coordinator signs JWT tokens with this secret when dispatching work to workers, and workers use it to verify requests came from the coordinator. A mismatch causes queries to hang indefinitely.

## Token Caching

```
Request with token "dapi..."
        │
        ▼
┌─ ConcurrentHashMap ─────────────────┐
│  token -> CacheEntry(email, time)   │
│                                     │
│  Hit + not expired?                 │
│    YES ──> return cached email      │
│    NO  ──> call Databricks SCIM API │
│            store result in cache    │
│            return email             │
└─────────────────────────────────────┘
```

- Default TTL: 300 seconds (5 minutes)
- Default max entries: 1000
- Eviction: expired entries removed first, then full clear if still over limit

## Network Requirements

| From | To | Port | Protocol | Purpose |
|------|----|------|----------|---------|
| Databricks Serverless | Trino Coordinator | 9443 | HTTPS | Client queries |
| Trino Coordinator | Databricks API | 443 | HTTPS | Token validation |
| Trino Coordinator | Workers | 8889 | HTTP+JWT | Task distribution |
| Workers | Trino Coordinator | 8889 | HTTP+JWT | Discovery, results |

Ensure security groups / firewall rules allow these flows.
